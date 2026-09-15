# Security and privacy

## Keep configuration local

Do not commit device names or identifiers, account names, local IP addresses, Mac hostnames, passwords, private or public SSH keys, signing identities, provisioning profiles, or configured Shortcut exports. Device settings belong in the installed tool's private `config` directory outside the checkout. SSH settings belong in your own Shortcuts/SSH configuration.

This tool can stop a running Xcode scheme action and build/run whichever workspace is active. Only give SSH access to trusted clients. Authenticate as the logged-in development user, keep normal SSH host verification enabled, and use a trusted network. The installer does not configure SSH, adjust the firewall, or grant macOS permissions.

## Reporting a problem

For ordinary bugs, open a GitHub issue with sanitized reproduction steps and software versions. Replace all device details and paths with placeholders and review any screenshots or logs before posting. Never paste credentials.

For a vulnerability, use this repository's **Security → Report a vulnerability** option if available. If it is unavailable, open an issue requesting a private contact method without including exploit details or secrets. Do not publish working credentials in a report. Revoke any exposed key or token immediately; removing a file from the latest commit does not erase earlier Git history.

## Scope of checks

Automated checks cover syntax and isolated installer behavior. They cannot certify the security of an SSH server, installed Xcode projects, or a user's Shortcuts configuration.
