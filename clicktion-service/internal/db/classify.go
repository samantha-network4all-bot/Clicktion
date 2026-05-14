package db

import (
	"net"
	"net/url"
)

// ClassifyLocal returns true if the URL resolves to a local/private address.
func ClassifyLocal(rawURL string) bool {
	u, err := url.Parse(rawURL)
	if err != nil {
		return false
	}
	host := u.Hostname()
	localNames := []string{"localhost", "127.0.0.1", "::1"}
	for _, n := range localNames {
		if host == n {
			return true
		}
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	private := []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"}
	for _, cidr := range private {
		_, network, _ := net.ParseCIDR(cidr)
		if network.Contains(ip) {
			return true
		}
	}
	return false
}
