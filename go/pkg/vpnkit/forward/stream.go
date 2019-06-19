package forward

import (
	"log"

	"github.com/moby/vpnkit/go/pkg/libproxy"
	"github.com/moby/vpnkit/go/pkg/vpnkit"
)

// Listen on stream sockets and forward to a remote multiplexer.

type network interface {
	listen(vpnkit.Port) (listener, error)
}

type listener interface {
	accept() (libproxy.Conn, error)
	close() error
}

func makeStream(c common, n network) (*stream, error) {
	l, err := n.listen(c.port)
	if err != nil {
		return nil, err
	}

	return &stream{
		c,
		l,
	}, nil
}

type stream struct {
	common
	l listener
}

func (s *stream) Run() {
	for {
		src, err := s.l.accept()
		if err != nil {
			log.Printf("Stopping accepting connections on %s", s.port.String())
			return
		}
		mux := s.ctrl.Mux()
		dest, err := mux.Dial(*s.dest)
		if err != nil {
			log.Printf("unable to connect on %s: %s", s.port.String(), err)
			if err := src.Close(); err != nil {
				log.Printf("unable to Close on %s: %s", s.port.String(), err)
			}
			return
		}
		go func() {
			if err := libproxy.ProxyStream(src, dest, s.quit); err != nil {
				log.Printf("unable to proxy on %s: %s", s.port.String(), err)
			}
			if err := src.Close(); err != nil {
				log.Printf("unable to Close on %s: %s", s.port.String(), err)
			}
		}()

	}
}

func (s *stream) Stop() {
	log.Printf("Removing %s", s.port.String())
	s.l.close()
	close(s.quit)
}
