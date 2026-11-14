"""Shared Terraform installs and bounded local workspace usage; no cloud operations."""
import argparse
import contextlib
import hashlib
import json
import math
import os
import re
import shutil
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path

GIB = 1024 ** 3


def reparse(path):
    return path.is_symlink() or bool(getattr(path.lstat(), 'st_file_attributes', 0) & 0x400)


def disk_bytes(root):
    if not root.exists():
        return 0
    seen, metadata, total, pending = set(), {}, 0, [root]
    while pending:
        with os.scandir(pending.pop()) as entries:
            for entry in entries:
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & 0x400:
                    continue
                if stat.S_ISDIR(info.st_mode):
                    pending.append(entry.path)
                elif stat.S_ISREG(info.st_mode):
                    if info.st_ino:
                        key = (info.st_dev, info.st_ino)
                        if key not in seen:
                            seen.add(key)
                            total += info.st_size
                    else:
                        # Windows enumeration omits file IDs. Hardlinks share these metadata;
                        # open handles only for collisions, rather than a million ordinary files.
                        key = (info.st_size, info.st_mtime_ns, info.st_ctime_ns)
                        if key not in metadata:
                            metadata[key] = [entry.path, None]
                            total += info.st_size
                        else:
                            group = metadata[key]
                            if group[1] is None:
                                first = os.stat(group[0], follow_symlinks=False)
                                group[1] = {(first.st_dev, first.st_ino)}
                            actual = os.stat(entry.path, follow_symlinks=False)
                            identity = (actual.st_dev, actual.st_ino)
                            if identity not in group[1] or not actual.st_ino:
                                group[1].add(identity)
                                total += info.st_size
    return total


def policy(root):
    root = Path(root).expanduser().resolve()
    if not root.is_dir() or root == Path(root.anchor):
        raise RuntimeError('An existing workspace directory is required')
    profile = root / '.tools/workspace-resources.json'
    data = json.loads(profile.read_text(encoding='utf-8-sig')) if profile.exists() else {}
    if not isinstance(data, dict):
        raise RuntimeError('Workspace resource profile must be an object')
    cache = os.environ.get('TF_PLUGIN_CACHE_DIR') or data.get('cache_dir')
    if not cache:
        base = Path(os.environ.get('LOCALAPPDATA', Path.home() / '.cache'))
        cache = base / 'Hexagon/terraform/providers'
    values = {'root': root, 'cache': Path(cache).expanduser().resolve(),
              'workspace_gib': float(data.get('workspace_gib', 50)), 'cache_gib': float(data.get('cache_gib', 15))}
    if any(not math.isfinite(values[k]) or values[k] <= 0 for k in ('workspace_gib', 'cache_gib')):
        raise RuntimeError('Resource budgets must be finite positive numbers')
    if values['cache'].is_relative_to((root / '.worktrees').resolve()) or values['cache'] in (root, Path(values['cache'].anchor)):
        raise RuntimeError('Shared provider cache must be outside disposable worktrees')
    return values


def check(settings, cache_only=False):
    cache = disk_bytes(settings['cache'])
    if cache > settings['cache_gib'] * GIB:
        raise RuntimeError(f'Shared provider cache {cache / GIB:.2f} GiB exceeds {settings["cache_gib"]:.2f} GiB; review unused versions before continuing')
    scope = settings['root'] / '.worktrees'
    if not scope.exists():
        scope = settings['root']
    workspace = None if cache_only else disk_bytes(scope)
    if workspace is not None and workspace > settings['workspace_gib'] * GIB:
        raise RuntimeError(f'Temporary workspace {workspace / GIB:.2f} GiB exceeds {settings["workspace_gib"]:.2f} GiB; run reviewed cleanup before allocating more data')
    return {'scope': str(scope), 'workspace_bytes': workspace, 'cache_bytes': cache,
            'workspace_limit_gib': settings['workspace_gib'], 'cache_limit_gib': settings['cache_gib']}


def configure(root, cache=None, workspace_gib=None, cache_gib=None, cli_config=None):
    root = Path(root).resolve()
    initial = policy(root)
    workspace_gib = initial['workspace_gib'] if workspace_gib is None else workspace_gib
    cache_gib = initial['cache_gib'] if cache_gib is None else cache_gib
    cache = Path(cache).expanduser().resolve() if cache else initial['cache']
    if cache.is_relative_to((root / '.worktrees').resolve()) or cache in (root, Path(cache.anchor)):
        raise RuntimeError('Shared cache cannot be inside .worktrees')
    if any(not math.isfinite(v) or v <= 0 for v in (workspace_gib, cache_gib)):
        raise RuntimeError('Budgets must be positive finite numbers')
    cli = Path(cli_config) if cli_config else Path(os.environ.get('TF_CLI_CONFIG_FILE') or (
        str(Path(os.environ['APPDATA']) / 'terraform.rc') if os.name == 'nt' else str(Path.home() / '.terraformrc')))
    text = cli.read_text(encoding='utf-8-sig') if cli.exists() else ''
    matches = re.findall(r'^\s*plugin_cache_dir\s*=\s*"([^"]+)"', text, re.M)
    if matches and (len(matches) != 1 or Path(os.path.expandvars(matches[0])).expanduser().resolve() != cache):
        raise RuntimeError('Existing Terraform CLI cache configuration differs; retained for explicit review')
    profile = root / '.tools/workspace-resources.json'
    if not profile.resolve().is_relative_to(root):
        raise RuntimeError('Workspace profile is redirected outside the workspace')
    cache.mkdir(parents=True, exist_ok=True)
    if not matches:
        cli.parent.mkdir(parents=True, exist_ok=True)
        with cli.open('a', encoding='utf-8', newline='\n') as stream:
            stream.write('\n# Hexagon shared provider cache\nplugin_cache_dir = ' + json.dumps(cache.as_posix()) + '\n')
    profile.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({'cache_dir': str(cache), 'workspace_gib': workspace_gib, 'cache_gib': cache_gib}, indent=2) + '\n'
    if not profile.exists() or profile.read_text(encoding='utf-8') != payload:
        profile.write_text(payload, encoding='utf-8')
    stable = root / '.tools/workspace_resources.py'
    if Path(__file__).resolve() != stable.resolve():
        shutil.copyfile(__file__, stable)
    instructions = root / 'AGENTS.md'
    existing = instructions.read_text(encoding='utf-8') if instructions.exists() else ''
    block = ('<!-- hexagon-resources:start -->\n'
             '## Recursos locales de Hexagon\n\n'
             'Antes de crear worktrees o instalar/restaurar/compilar dependencias, ejecutar:\n\n'
             '```powershell\npython "' + stable.as_posix() + '" check --workspace-root "' + root.as_posix() + '"\n```\n\n'
             'Si excede el presupuesto, detener nuevas asignaciones y limpiar solo candidatos verificados.\n'
             'No aumentar límites automáticamente. Inventario, configuración, limpieza y pruebas unitarias\n'
             'aisladas pueden ejecutarse para resolver el bloqueo.\n'
             'Usar el subcomando init de ese mismo helper para terraform init: serializa la caché, conserva\n'
             'checksums y exige enlaces compartidos. No usar copias privadas de proveedores ni compartir\n'
             'node_modules entre versiones distintas. Reservar worktrees activos y retirar los terminados.\n'
             'Estas reglas no autorizan cloud, publicaciones, fusiones ni eliminación de datos de producto.\n'
             '<!-- hexagon-resources:end -->')
    if '<!-- hexagon-resources:start -->' in existing:
        updated = re.sub(r'<!-- hexagon-resources:start -->.*?<!-- hexagon-resources:end -->', lambda _: block, existing, flags=re.S)
    else:
        updated = existing.rstrip() + ('\n\n' if existing.strip() else '') + block + '\n'
    if updated != existing:
        instructions.write_text(updated, encoding='utf-8')
    claude = root / 'CLAUDE.md'
    claude_text = claude.read_text(encoding='utf-8') if claude.exists() else ''
    if not re.search(r'^\s*@AGENTS\.md\s*$', claude_text, re.M):
        with claude.open('a', encoding='utf-8') as stream:
            stream.write('\n<!-- Hexagon shared workspace rules -->\n@AGENTS.md\n')
    return {'profile': str(profile), 'cli_config': str(cli), 'cache_dir': str(cache)}


@contextlib.contextmanager
def install_lock(cache, timeout=60):
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / '.hexagon-install.lock'
    if path.exists() and reparse(path):
        raise RuntimeError('Cache lock path is redirected')
    with path.open('a+b') as stream:
        if path.stat().st_size == 0:
            stream.write(b'0')
            stream.flush()
        deadline = time.monotonic() + timeout
        while True:
            try:
                stream.seek(0)
                if os.name == 'nt':
                    import msvcrt
                    msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise RuntimeError('Provider cache is in use; no concurrent initialization allowed')
                time.sleep(0.1)
        try:
            yield
        finally:
            stream.seek(0)
            if os.name == 'nt':
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(stream.fileno(), fcntl.LOCK_UN)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(block)
    return digest.digest()


def deduplicate(providers, cache):
    count = 0
    if not providers.exists():
        return count
    if reparse(providers.parent):
        raise RuntimeError('Terraform data directory is redirected')
    if reparse(providers):
        if not providers.resolve().is_relative_to(cache):
            raise RuntimeError('Provider directory points outside the managed cache')
        return count
    for current, directories, files in os.walk(providers, followlinks=False):
        for name in list(directories):
            path = Path(current) / name
            if reparse(path):
                if not path.resolve().is_relative_to(cache):
                    raise RuntimeError('Provider link points outside the managed cache')
                directories.remove(name)
        for name in files:
            local = Path(current) / name
            shared = cache / local.relative_to(providers)
            if not shared.is_file() or not shared.resolve().is_relative_to(cache):
                raise RuntimeError('Provider did not come from the managed shared cache')
            if os.path.samefile(local, shared):
                continue
            if reparse(local) or sha256(local) != sha256(shared):
                raise RuntimeError('Provider content differs from the shared cache; retained')
            temporary = local.parent / ('.hexagon-link-' + uuid.uuid4().hex)
            try:
                os.link(shared, temporary)
                os.replace(temporary, local)
                if not os.path.samefile(local, shared):
                    raise RuntimeError('Provider sharing could not be verified')
                count += 1
            finally:
                if temporary.exists():
                    temporary.unlink()
    return count


def initialize(root, settings, arguments=(), cache_only=False, executable=None):
    root = Path(root).resolve()
    if not root.is_dir() or not root.is_relative_to(settings['root']):
        raise RuntimeError('Terraform root must be inside the selected workspace')
    if os.environ.get('TF_DATA_DIR'):
        raise RuntimeError('Custom TF_DATA_DIR requires a separate reviewed resource policy')
    data_directory = root / '.terraform'
    if data_directory.exists() and reparse(data_directory):
        raise RuntimeError('Terraform data directory is redirected')
    check(settings, cache_only)
    cache = settings['cache']
    cache.mkdir(parents=True, exist_ok=True)
    with install_lock(cache):
        check(settings, cache_only)
        if shutil.disk_usage(cache).free < 2 * GIB:
            raise RuntimeError('Less than 2 GiB free; initialization stopped')
        program = executable or shutil.which('terraform')
        if not program:
            raise RuntimeError('Terraform executable not found')
        env = dict(os.environ, TF_PLUGIN_CACHE_DIR=str(cache))
        result = subprocess.run([program, '-chdir=' + str(root), 'init', *arguments], env=env)
        if result.returncode:
            return result.returncode
        deduplicate(root / '.terraform/providers', cache)
        check(settings, cache_only)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('configure', 'check', 'init'))
    parser.add_argument('--workspace-root', required=True)
    parser.add_argument('--cache-dir')
    parser.add_argument('--workspace-gib', type=float)
    parser.add_argument('--cache-gib', type=float)
    parser.add_argument('--root')
    parser.add_argument('--cache-only', action='store_true', help='Coordinator already checked workspace; still enforce cache budget and sharing')
    args, extra = parser.parse_known_args()
    try:
        if args.action != 'init' and extra:
            raise RuntimeError('Unexpected arguments')
        if args.action != 'configure' and any(value is not None for value in (args.cache_dir, args.workspace_gib, args.cache_gib)):
            raise RuntimeError('Resource settings are changed only with configure')
        if args.action == 'configure':
            result = configure(args.workspace_root, args.cache_dir, args.workspace_gib, args.cache_gib)
        else:
            settings = policy(args.workspace_root)
            if args.action == 'check':
                if extra:
                    raise RuntimeError('Unexpected arguments')
                result = check(settings, args.cache_only)
            else:
                if not args.root:
                    raise RuntimeError('--root is required for init')
                return initialize(args.root, settings, extra[1:] if extra[:1] == ['--'] else extra, args.cache_only)
        print(json.dumps(result, indent=2))
        return 0
    except RuntimeError as error:
        print('Resource policy: ' + str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError):
        print('Resource policy failed: verify workspace/cache budgets, configuration, locks and provider sharing. No automatic cleanup performed.', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
