# Proxy Config

Configurations for Clash, Surge, Shadowrocket, etc.

These configurations are only suitable for myself.

Update [rule providers](clash/rule_provider/) for clash, and then generate rule sets for other apps:

```bash
./generate.sh
```

To get a Clash config you can paste into OpenClash or ClashVerge, copy `clash/secrets.yaml.example` to `clash/secrets.yaml`, fill it in, and run the command below. It writes `clash/config.local.yaml` and `surge/default.local.conf` (Surge node-domain `[Host]` entries) and copies the Clash one to the clipboard (needs `yq`):

```bash
./scripts/render.sh --copy
```
