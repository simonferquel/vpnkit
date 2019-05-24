package transport

import (
	"context"
	"net"
	"strconv"

	"github.com/linuxkit/virtsock/pkg/vsock"
)

func NewVsockTransport() Transport {

	return &vs{}
}

type vs struct {
}

func (_ *vs) Dial(_ context.Context, path string) (net.Conn, error) {
	port, err := parsePort(path)
	if err != nil {
		return nil, err
	}
	return vsock.Dial(vsock.CIDHost, uint32(port))
}

func (_ *vs) Listen(path string) (net.Listener, error) {
	port, err := parsePort(path)
	if err != nil {
		return nil, err
	}
	return vsock.Listen(vsock.CIDAny, uint32(port))
}

func parsePort(path string) (int, error) {
	v, err := strconv.ParseUint(path, 10, 32)
	return int(v), err
}
