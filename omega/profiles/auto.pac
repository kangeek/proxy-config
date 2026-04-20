function FindProxyForURL(url, host) {

  // ===== 1. 本地域名 / 单标签主机名 =====
  if (isPlainHostName(host)) {
    return "DIRECT";
  }

  // ===== 2. 局域网 IP 直连 =====
  if (
    isInNet(host, "127.0.0.0", "255.0.0.0") ||
    isInNet(host, "10.0.0.0", "255.0.0.0") ||
    isInNet(host, "172.16.0.0", "255.240.0.0") ||
    isInNet(host, "192.168.0.0", "255.255.0.0")
  ) {
    return "DIRECT";
  }

  // ===== 3. 指定网站 bypass =====
  if (
    dnsDomainIs(host, ".paymaya.com") ||
    dnsDomainIs(host, ".corp.voyager.ph") ||
    shExpMatch(host, "*.corp.maya*")
  ) {
    return "DIRECT";
  }

  // ===== 4. 默认代理：远程优先，本地兜底 =====
  return "SOCKS5 192.168.192.88:7890; SOCKS5 192.168.88.1:7890; SOCKS5 127.0.0.1:7890; DIRECT";
}