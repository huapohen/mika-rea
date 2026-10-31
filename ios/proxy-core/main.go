// SPDX-License-Identifier: GPL-3.0-or-later
// Mika's single-tunnel bridge: local developer packets never enter proxy routing.
package main

/*
#include <stdint.h>
*/
import "C"

import (
	"encoding/binary"
	"errors"
	"io"
	"os"
	"runtime/debug"
	"sync"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/config"
	constant "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	singtun "github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	tun "github.com/metacubex/sing-tun"
	"gopkg.in/yaml.v3"
)

type packetDevice struct {
	input, output chan []byte
	done          chan struct{}
	once          sync.Once
}

func newPacketDevice() *packetDevice {
	return &packetDevice{make(chan []byte, 128), make(chan []byte, 128), make(chan struct{}), sync.Once{}}
}
func (d *packetDevice) Read(p []byte) (int, error) {
	select {
	case data := <-d.input:
		if len(data) > len(p) {
			return 0, io.ErrShortBuffer
		}
		return copy(p, data), nil
	case <-d.done:
		return 0, io.EOF
	}
}
func (d *packetDevice) Write(p []byte) (int, error) {
	data := append([]byte(nil), p...)
	select {
	case d.output <- data:
		return len(p), nil
	case <-d.done:
		return 0, io.EOF
	}
}
func (d *packetDevice) Close() error { d.once.Do(func() { close(d.done) }); return nil }
func (d *packetDevice) submit(p []byte) bool {
	if !validPacket(p) {
		return false
	}
	data := append([]byte(nil), p...)
	destination := d.input
	if localDeveloperPacket(data) {
		reflectIPv4(data)
		destination = d.output
	}
	select {
	case <-d.done:
		return false
	default:
	}
	select {
	case destination <- data:
		return true
	default:
		return false
	}
}
func validPacket(p []byte) bool {
	if len(p) < 1 {
		return false
	}
	switch p[0] >> 4 {
	case 4:
		if len(p) < 20 {
			return false
		}
		header := int(p[0]&15) * 4
		length := int(binary.BigEndian.Uint16(p[2:4]))
		return header >= 20 && header <= len(p) && length == len(p)
	case 6:
		return len(p) >= 40 && int(binary.BigEndian.Uint16(p[4:6]))+40 == len(p)
	}
	return false
}
func localDeveloperPacket(p []byte) bool {
	return len(p) >= 20 && p[0]>>4 == 4 && p[16] == 10 && p[17] == 7 && p[18] == 0 && p[19] == 1
}
func reflectIPv4(p []byte) {
	for i := 0; i < 4; i++ {
		p[12+i], p[16+i] = p[16+i], p[12+i]
	}
}

var lifecycle sync.Mutex
var activeMu sync.RWMutex
var active *packetDevice

func device() *packetDevice { activeMu.RLock(); defer activeMu.RUnlock(); return active }
func prepareConfig(data []byte) ([]byte, error) {
	if len(data) == 0 || len(data) > 2*1024*1024 {
		return nil, errors.New("config size")
	}
	var raw map[string]any
	if err := yaml.Unmarshal(data, &raw); err != nil {
		return nil, errors.New("config format")
	}
	if raw == nil {
		return nil, errors.New("empty config")
	}
	// These are owned by the extension, never by downloaded configuration.
	raw["tun"] = map[string]any{"enable": true, "stack": "mips", "device": "utun0", "mtu": 1500, "auto-route": false, "auto-detect-interface": false, "inet4-address": []string{"198.18.0.1/30"}, "inet6-address": []string{"fdfe:dcba:9876::1/126"}, "dns-hijack": []string{"any:53", "tcp://any:53"}}
	raw["external-controller"] = ""
	raw["external-controller-tls"] = ""
	raw["external-controller-unix"] = ""
	raw["external-controller-pipe"] = ""
	raw["allow-lan"] = false
	raw["bind-address"] = "127.0.0.1"
	raw["log-level"] = "silent"
	raw["port"] = 0
	raw["socks-port"] = 0
	raw["mixed-port"] = 0
	raw["redir-port"] = 0
	raw["tproxy-port"] = 0
	// Explicit inbound listeners could bypass the app's local-only interface policy.
	delete(raw, "listeners")
	delete(raw, "tunnels")
	dns, ok := raw["dns"].(map[string]any)
	if !ok {
		dns = map[string]any{}
	}
	dns["enable"] = true
	dns["listen"] = ""
	dns["ipv6"] = true
	if _, ok := dns["nameserver"]; !ok {
		dns["nameserver"] = []string{"223.5.5.5", "119.29.29.29"}
	}
	raw["dns"] = dns
	return yaml.Marshal(raw)
}
func startCore(data []byte, directory string) int {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if device() != nil {
		return -3
	}
	normalized, err := prepareConfig(data)
	if err != nil {
		return -1
	}
	if err = os.MkdirAll(directory, 0700); err != nil {
		return -2
	}
	debug.SetMemoryLimit(28 * 1024 * 1024)
	log.SetLevel(log.SILENT)
	constant.SetHomeDir(directory)
	cfg, err := config.Parse(normalized)
	if err != nil {
		return -1
	}
	d := newPacketDevice()
	singtun.CustomTunFactory = func(tun.Options) (tun.Tun, error) { return d, nil }
	executor.ApplyConfig(cfg, true)
	if !listener.GetTunConf().Enable {
		d.Close()
		executor.Shutdown()
		singtun.CustomTunFactory = nil
		return -4
	}
	activeMu.Lock()
	active = d
	activeMu.Unlock()
	return 0
}
func stopCore() {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	d := device()
	if d == nil {
		return
	}
	d.Close()
	executor.Shutdown()
	singtun.CustomTunFactory = nil
	activeMu.Lock()
	active = nil
	activeMu.Unlock()
}

//export mika_proxy_start
func mika_proxy_start(configuration *C.char, directory *C.char) C.int {
	if configuration == nil || directory == nil {
		return -1
	}
	return C.int(startCore([]byte(C.GoString(configuration)), C.GoString(directory)))
}

//export mika_proxy_stop
func mika_proxy_stop() { stopCore() }

//export mika_proxy_input
func mika_proxy_input(packet *C.uchar, length C.int) C.int {
	d := device()
	if d == nil || packet == nil || length < 1 || length > 65535 {
		return -1
	}
	if !d.submit(unsafe.Slice((*byte)(unsafe.Pointer(packet)), int(length))) {
		return -2
	}
	return 0
}

//export mika_proxy_read
func mika_proxy_read(output *C.uchar, capacity C.int) C.int {
	d := device()
	if d == nil || output == nil || capacity < 65535 {
		return -1
	}
	select {
	case p := <-d.output:
		copy(unsafe.Slice((*byte)(unsafe.Pointer(output)), int(capacity)), p)
		return C.int(len(p))
	case <-d.done:
		return -1
	case <-time.After(300 * time.Millisecond):
		return 0
	}
}
func main() {}
