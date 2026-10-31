package main

import (
	"bytes"
	"encoding/binary"
	"net"
	"testing"
	"time"
)

func udpPacket(source, destination net.IP, sourcePort, destinationPort uint16, payload []byte) []byte {
	p := make([]byte, 28+len(payload))
	p[0] = 0x45
	p[8] = 64
	p[9] = 17
	binary.BigEndian.PutUint16(p[2:4], uint16(len(p)))
	copy(p[12:16], source.To4())
	copy(p[16:20], destination.To4())
	binary.BigEndian.PutUint16(p[20:22], sourcePort)
	binary.BigEndian.PutUint16(p[22:24], destinationPort)
	binary.BigEndian.PutUint16(p[24:26], uint16(8+len(payload)))
	copy(p[28:], payload)
	var sum uint32
	for i := 0; i < 20; i += 2 {
		sum += uint32(binary.BigEndian.Uint16(p[i : i+2]))
	}
	for sum>>16 != 0 {
		sum = (sum & 65535) + (sum >> 16)
	}
	binary.BigEndian.PutUint16(p[10:12], ^uint16(sum))
	return p
}
func TestLocalPacketsNeverEnterProxy(t *testing.T) {
	d := newPacketDevice()
	defer d.Close()
	p := udpPacket(net.IPv4(10, 7, 1, 1), net.IPv4(10, 7, 0, 1), 23456, 49152, []byte("local-only"))
	if !d.submit(p) {
		t.Fatal("submit failed")
	}
	select {
	case reflected := <-d.output:
		if !bytes.Equal(reflected[12:16], p[16:20]) || !bytes.Equal(reflected[16:20], p[12:16]) {
			t.Fatal("incorrect reflection")
		}
		if !bytes.Equal(reflected[20:], p[20:]) {
			t.Fatal("transport payload changed")
		}
		if !bytes.Equal(reflected[10:12], p[10:12]) {
			t.Fatal("checksum changed")
		}
	default:
		t.Fatal("no reflected packet")
	}
	select {
	case <-d.input:
		t.Fatal("pairing traffic entered proxy")
	default:
	}
	if d.submit([]byte{0x45}) {
		t.Fatal("accepted malformed packet")
	}
}
func TestProxyStackUDPForwarding(t *testing.T) {
	var destination net.IP
	interfaces, _ := net.Interfaces()
	for _, iface := range interfaces {
		addresses, _ := iface.Addrs()
		for _, address := range addresses {
			ip, _, _ := net.ParseCIDR(address.String())
			if ip != nil && ip.To4() != nil && !ip.IsLoopback() && ip.IsGlobalUnicast() {
				destination = ip.To4()
				break
			}
		}
		if destination != nil {
			break
		}
	}
	if destination == nil {
		t.Skip("no local IPv4 interface")
	}
	server, err := net.ListenUDP("udp4", &net.UDPAddr{IP: destination})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	go func() {
		buffer := make([]byte, 128)
		n, addr, e := server.ReadFromUDP(buffer)
		if e == nil {
			server.WriteToUDP(append([]byte("reply:"), buffer[:n]...), addr)
		}
	}()
	if code := startCore([]byte("mode: direct\nrules:\n - MATCH,DIRECT\n"), t.TempDir()); code != 0 {
		t.Fatalf("start returned %d", code)
	}
	defer stopCore()
	d := device()
	p := udpPacket(net.IPv4(198, 18, 0, 1), destination, 24567, uint16(server.LocalAddr().(*net.UDPAddr).Port), []byte("MIKA_PROXY_OK"))
	if !d.submit(p) {
		t.Fatal("submit failed")
	}
	select {
	case reply := <-d.output:
		if len(reply) < 28 || !bytes.Equal(reply[28:], []byte("reply:MIKA_PROXY_OK")) {
			t.Fatalf("incorrect response (%d bytes)", len(reply))
		}
	case <-time.After(10 * time.Second):
		t.Fatal("proxy packet forwarding timed out")
	}
}
func TestConfigCannotExposeControllerOrOtherInbounds(t *testing.T) {
	data, err := prepareConfig([]byte("mode: direct\nexternal-controller: 0.0.0.0:9090\nallow-lan: true\nlisteners:\n - name: unwanted\n   type: socks\n   port: 1234\n"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, []byte("0.0.0.0:9090")) || bytes.Contains(data, []byte("unwanted")) {
		t.Fatal("untrusted listeners preserved")
	}
}
