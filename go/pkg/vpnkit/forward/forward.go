package forward

// Listen on TCP/UDP/Unix sockets and forward to a remote multiplexer.

import (
	"errors"
	"log"

	"github.com/moby/vpnkit/go/pkg/libproxy"
	"github.com/moby/vpnkit/go/pkg/vpnkit"
)

// Forward listens for incoming connections from the "outside" and forwards them to a remote.
type Forward interface {
	Run()              // Run the accept loop
	Stop()             // Stop the accept loop
	Port() vpnkit.Port // Port describes the forwards
}

func Make(ctrl vpnkit.Control, port vpnkit.Port) (Forward, error) {
	log.Printf("Adding %s", port.String())
	dest := &libproxy.Destination{
		IP:   port.InIP,
		Port: port.InPort,
		Path: port.InPath,
	}
	quit := make(chan struct{})
	common := common{
		ctrl,
		port,
		dest,
		quit,
	}
	switch port.Proto {
	case vpnkit.TCP:
		dest.Proto = libproxy.TCP
		return makeTCP(common)
	case vpnkit.UDP:
		dest.Proto = libproxy.UDP
		return makeUDP(common)
	case vpnkit.Unix:
		dest.Proto = libproxy.Unix
		return makeUnix(common)
	}
	return nil, errors.New("cannot listen on unknown protocol " + string(port.Proto))
}

type common struct {
	ctrl vpnkit.Control
	port vpnkit.Port
	dest *libproxy.Destination
	quit chan struct{}
}

func (c *common) Port() vpnkit.Port {
	return c.port
}
