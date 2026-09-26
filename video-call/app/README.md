客户端代码。完整说明见上一级 [README.md](../README.md)。

```bash
# 先在仓库根目录启动局域网 Token / LiveKit
../scripts/dev.sh

# 另开终端跑 App，TOKEN_URL 换成电脑局域网 IP
export PATH="$HOME/flutter/bin:$PATH"
flutter run --dart-define=TOKEN_URL=http://<电脑局域网IP>:3000
```
