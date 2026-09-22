Client code. See the parent [README.md](../README.md) for the full setup.

```bash
# Start the LAN token service / LiveKit from the repo root first
../scripts/dev.sh

# In another terminal, run the app. Replace TOKEN_URL with this computer's LAN IP.
export PATH="$HOME/flutter/bin:$PATH"
flutter run --dart-define=TOKEN_URL=http://<LAN-IP>:3000
```
