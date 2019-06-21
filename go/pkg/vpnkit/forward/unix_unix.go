// +build !windows

package forward

import (
	"github.com/moby/vpnkit/go/pkg/libproxy"
	"github.com/moby/vpnkit/go/pkg/vpnkit"
	"github.com/pkg/errors"
	"net"
	"os"
	"path/filepath"
	"syscall"
)

type unixNetwork struct{}

func (t *unixNetwork) listen(port vpnkit.Port) (listener, error) {
	if err := removeExistingSocket(port.OutPath); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(port.OutPath), 0755); err != nil && !os.IsExist(err) {
		return nil, errors.Wrapf(err, "making %s", filepath.Dir(port.OutPath))
	}
	l, err := net.ListenUnix("unix", &net.UnixAddr{
		Net:  "unix",
		Name: port.OutPath,
	})
	if err != nil {
		return nil, err
	}
	wrapped := unixListener{l}
	return &wrapped, nil
}

type unixListener struct {
	l *net.UnixListener
}

func (l unixListener) accept() (libproxy.Conn, error) {
	return l.l.AcceptUnix()
}

func (l unixListener) close() error {
	return l.l.Close()
}

func makeUnix(c common) (Forward, error) {
	return makeStream(c, &unixNetwork{})
}

func removeExistingSocket(path string) error {
	// Only remove a path if it is a Unix domain socket. Don't remove arbitrary files
	// by accident.
	if !isSafeToRemove(path) {
		return errors.New("refusing to remove path " + path)
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return errors.Wrap(err, "removing "+path)
	}
	return nil
}

// isSaveToRemove returns true if the path references a Unix domain socket or named pipe
// or if the path doesn't exist at all
func isSafeToRemove(path string) bool {
	var statT syscall.Stat_t
	if err := syscall.Stat(path, &statT); err != nil {
		if os.IsNotExist(err) {
			return true
		}
		return false // cannot stat suggests something is wrong
	}
	return statT.Mode&syscall.S_IFMT == syscall.S_IFSOCK
}
