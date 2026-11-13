namespace Hexagon.Database.Bootstrap;

/// <summary>The identity database role and the secrets of its password and of the initial Keycloak administrator.</summary>
internal sealed record AwsKeycloakLogins(string Role, string PasswordSecret, string BootstrapSecret);
