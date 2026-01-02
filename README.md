# Homelab Apps

Git-based application deployments for the homelab, managed via **Komodo**.

## Overview

This repository contains Docker Compose configurations for user-facing applications. These are deployed directly via Komodo's Git integration, without requiring Ansible playbook runs.

## Structure

```
homelab-apps/
├── README.md
├── mealie/
│   ├── docker-compose.yml
│   └── .env.example
├── vaultwarden/
│   ├── docker-compose.yml
│   └── .env.example
└── ... (future apps)
```

## Deployment

### Prerequisites

- Komodo Core running at `https://komodo.{env}.thebozic.com`
- Infisical CLI installed on target hosts
- GitHub token configured in Komodo for repo access

### Deploy a New App

1. Create stack in Komodo UI → Point to this repo
2. Set `Run Directory` to the app folder (e.g., `mealie`)
3. Configure environment variables (ENV, BASE_DOMAIN)
4. Add pre-deploy hook for Infisical secrets (if needed)
5. Deploy!

See [Homelab/docs/GIT_BASED_APPLICATION_DEPLOYMENT.md](https://github.com/LuckyPrayer/Homelab/blob/main/docs/GIT_BASED_APPLICATION_DEPLOYMENT.md) for detailed instructions.

## Environment Variables

All apps use these standard variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `ENV` | Environment (dev/prod) | `dev` |
| `BASE_DOMAIN` | Base domain for routing | `thebozic.com` |
| `TZ` | Timezone | `America/Toronto` |

App-specific secrets are stored in Infisical at `/services/{app-name}/`.

## Apps

| App | Description | Secrets Required |
|-----|-------------|------------------|
| [mealie](mealie/) | Recipe manager & meal planner | None |
| [vaultwarden](vaultwarden/) | Bitwarden-compatible password manager | `VAULTWARDEN_ADMIN_TOKEN`, SMTP credentials |

## Backup

Apps deployed from this repo store data in `/etc/komodo/stacks/{app}-{env}/data/`.

To integrate with existing backup system, create a symlink:
```bash
ln -s /etc/komodo/stacks/mealie-dev /opt/stacks/mealie
```

## License

MIT
