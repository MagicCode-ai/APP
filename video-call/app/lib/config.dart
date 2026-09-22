const kDefaultTokenApiUrl = 'http://192.168.1.8:3000';

String tokenApiUrlFromEnvironment() {
  const fromEnv = String.fromEnvironment('TOKEN_URL');
  if (fromEnv.isNotEmpty) {
    return fromEnv;
  }
  return kDefaultTokenApiUrl;
}
