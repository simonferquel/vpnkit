module Lwt_result = Hostnet_lwt_result (* remove when new Lwt is released *)

open Lwt.Infix

let src =
  let src = Logs.Src.create "Uwt" ~doc:"Host interface based on Uwt" in
  Logs.Src.set_level src (Some Logs.Info);
  src

module Log = (val Logs.src_log src : Logs.LOG)

let default_read_buffer_size = 65536

let log_exception_continue description f =
  Lwt.catch
    (fun () -> f ())
    (fun e ->
       Log.err (fun f -> f "%s: caught %s" description (Printexc.to_string e));
       Lwt.return ()
    )

let make_sockaddr (ip, port) =
  Unix.ADDR_INET (Unix.inet_addr_of_string @@ Ipaddr.to_string ip, port)

let string_of_address (dst, dst_port) =
  Ipaddr.to_string dst ^ ":" ^ (string_of_int dst_port)

let sockaddr_of_address (dst, dst_port) =
  Unix.ADDR_INET(Unix.inet_addr_of_string @@ Ipaddr.to_string dst, dst_port)

module Common = struct
  (** FLOW boilerplate *)

  type error = [
    | `Msg of string
  ]

  let error_message = function
    | `Msg x -> x

  let errorf fmt = Printf.ksprintf (fun s -> Lwt_result.fail (`Msg s)) fmt

  let ip_port_of_sockaddr sockaddr =
    try
      match sockaddr with
      | Unix.ADDR_INET(ip, port) ->
        Some (Ipaddr.of_string @@ Unix.string_of_inet_addr ip, port)
      | _ ->
        None
    with _ -> None

  type 'a io = 'a Lwt.t
  type buffer = Cstruct.t
end

module Sockets = struct

  let max_connections = ref None

  let set_max_connections x = max_connections := x

  let next_connection_idx =
    let idx = ref 0 in
    fun () ->
      let next = !idx in
      incr idx;
      next

  exception Too_many_connections

  let connection_table = Hashtbl.create 511
  let connections =
    Vfs.Dir.of_list
      (fun () ->
        Vfs.ok (
          Hashtbl.fold
            (fun _ c acc -> Vfs.Inode.dir c Vfs.Dir.empty :: acc)
            connection_table []
        )
      )
  let register_connection_no_limit description =
    let idx = next_connection_idx () in
    Hashtbl.replace connection_table idx description;
    idx
  let register_connection =
    let last_error_log = ref 0. in
    fun description -> match !max_connections with
    | Some m when Hashtbl.length connection_table >= m ->
      let now = Unix.gettimeofday () in
      if (now -. !last_error_log) > 30. then begin
        (* Avoid hammering the logging system *)
        Log.err (fun f -> f "exceeded maximum number of forwarded connections (%d)" m);
        last_error_log := now;
      end;
      Lwt.fail Too_many_connections
    | _ ->
      let idx = register_connection_no_limit description in
      Lwt.return idx
  let deregister_connection idx =
    if not(Hashtbl.mem connection_table idx) then begin
      Log.warn (fun f -> f "deregistered connection %d more than once" idx)
    end;
    Hashtbl.remove connection_table idx

  module Datagram = struct
    type address = Ipaddr.t * int

    module Udp = struct
      include Common

      type flow = {
        idx: int option;
        label: string;
        description: string;
        mutable fd: Uwt.Udp.t option;
        read_buffer_size: int;
        mutable already_read: Cstruct.t option;
        sockaddr: Unix.sockaddr;
        address: address;
      }

      type address = Ipaddr.t * int

      let string_of_flow t = Printf.sprintf "udp -> %s" (string_of_address t.address)

      let of_fd ?idx ?(read_buffer_size = Constants.max_udp_length) ?(already_read = None) ~description sockaddr address fd =
        let label = match fst address with
          | Ipaddr.V4 _ -> "UDPv4"
          | Ipaddr.V6 _ -> "UDPv6" in
        { idx; label; description; fd = Some fd; read_buffer_size; already_read; sockaddr; address }

      let connect ?read_buffer_size address =
        let description = "udp:" ^ (string_of_address address) in
        register_connection description
        >>= fun idx ->
        let label, fd, addr =
          try match fst @@ address with
            | Ipaddr.V4 _ -> "UDPv4", Uwt.Udp.init_ipv4_exn (), Unix.inet_addr_any
            | Ipaddr.V6 _ -> "UDPv6", Uwt.Udp.init_ipv6_exn (), Unix.inet6_addr_any
          with e -> deregister_connection idx; raise e in
        Lwt.catch
          (fun () ->
             let sockaddr = make_sockaddr address in
             let result = Uwt.Udp.bind fd ~addr:(Unix.ADDR_INET(addr, 0)) () in
             if not(Uwt.Int_result.is_ok result) then begin
               let error = Uwt.Int_result.to_error result in
               Log.err (fun f -> f "Socket.%s.connect(%s): %s" label (string_of_address address) (Uwt.strerror error));
               Lwt.fail (Unix.Unix_error(Uwt.to_unix_error error, "bind", ""))
             end else Lwt_result.return (of_fd ~idx ?read_buffer_size ~description sockaddr address fd)
          )
          (fun e ->
             (* FIXME(djs55): error handling *)
             deregister_connection idx;
             let _ = Uwt.Udp.close fd in
             errorf "Socket.%s.connect %s: caught %s" label description (Printexc.to_string e)
          )

      let rec read t = match t.fd, t.already_read with
        | None, _ -> Lwt.return `Eof
        | Some _, Some data when Cstruct.len data > 0 ->
          t.already_read <- Some (Cstruct.sub data 0 0); (* next read is `Eof *)
          Lwt.return (`Ok data)
        | Some _, Some _ ->
          Lwt.return `Eof
        | Some fd, None ->
          let buf = Cstruct.create t.read_buffer_size in
          Lwt.catch
            (fun () ->
              Uwt.Udp.recv_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len ~buf:buf.Cstruct.buffer fd
              >>= fun recv ->
              if recv.Uwt.Udp.is_partial then begin
                Log.err (fun f -> f "Socket.%s.recvfrom: dropping partial response (buffer was %d bytes)" t.label (Cstruct.len buf));
                read t
              end else Lwt.return (`Ok (Cstruct.sub buf 0 recv.Uwt.Udp.recv_len))
            ) (function
              | Uwt.Uwt_error(Uwt.ECANCELED, _, _) ->
                (* happens on normal timeout *)
                Lwt.return `Eof
              | e ->
                Log.err (fun f -> f "Socket.%s.recvfrom: %s caught %s returning Eof"
                  t.label
                  (string_of_flow t)
                  (Printexc.to_string e)
                );
                Lwt.return `Eof
            )

      let write t buf = match t.fd with
        | None -> Lwt.return `Eof
        | Some fd ->
          Lwt.catch
            (fun () ->
               Uwt.Udp.send_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len ~buf:buf.Cstruct.buffer fd t.sockaddr
               >>= fun () ->
               Lwt.return (`Ok ())
            ) (fun e ->
                Log.err (fun f -> f "Socket.%s.write %s: caught %s returning Eof"
                  t.label t.description (Printexc.to_string e));
                Lwt.return `Eof
              )

      let writev t bufs = write t (Cstruct.concat bufs)

      let close t = match t.fd with
        | None -> Lwt.return_unit
        | Some fd ->
          t.fd <- None;
          Log.debug (fun f -> f "Socket.%s.close: %s" t.label (string_of_flow t));
          (* FIXME(djs55): errors *)
          let _ = Uwt.Udp.close fd in
          (match t.idx with Some idx -> deregister_connection idx | None -> ());
          Lwt.return_unit

      let shutdown_read _t = Lwt.return_unit
      let shutdown_write _t = Lwt.return_unit

      type server = {
        idx: int;
        label: string;
        fd: Uwt.Udp.t;
        mutable closed: bool;
      }

      let make ~idx ~label fd = { idx; label; fd; closed = false }

      let bind (ip, port) =
        let description = "udp:" ^ (Ipaddr.to_string ip) ^ ":" ^ (string_of_int port) in
        let sockaddr = make_sockaddr(ip, port) in
        register_connection description
        >>= fun idx ->
        let fd = try Uwt.Udp.init () with e -> deregister_connection idx; raise e in
        let result = Uwt.Udp.bind ~mode:[ Uwt.Udp.Reuse_addr ] fd ~addr:sockaddr () in
        let label = match ip with
          | Ipaddr.V4 _ -> "UDPv4"
          | Ipaddr.V6 _ -> "UDPv6" in
        let t = make ~idx ~label fd in
        if not(Uwt.Int_result.is_ok result) then begin
          let error = Uwt.Int_result.to_error result in
          Log.debug (fun f -> f "Socket.%s.bind(%s, %d): %s" t.label (Ipaddr.to_string ip) port (Uwt.strerror error));
          deregister_connection idx;
          Lwt.fail (Unix.Unix_error(Uwt.to_unix_error error, "bind", ""))
        end else Lwt.return t

      let of_bound_fd ?read_buffer_size:_ fd =
        match Uwt.Udp.openudp fd with
        | Uwt.Ok fd ->
          let label, description = match Uwt.Udp.getsockname fd with
            | Uwt.Ok sockaddr ->
               begin match ip_port_of_sockaddr sockaddr with
               | Some (Some ip, port) ->
                 "udp:" ^ (Ipaddr.to_string ip) ^ ":" ^ (string_of_int port),
                 begin match ip with
                   | Ipaddr.V4 _ -> "UDPv4"
                   | Ipaddr.V6 _ -> "UDPv6"
                 end
               | _ -> "unknown incoming UDP", "UDP?"
               end
            | Uwt.Error error -> "Socket.UDP?.of_bound_fd: getpeername failed: " ^ (Uwt.strerror error), "UDP?" in
          let idx = register_connection_no_limit description in
          make ~idx ~label fd
        | Uwt.Error error ->
          let msg = Printf.sprintf "Socket.UDP?.of_bound_fd failed with %s" (Uwt.strerror error) in
          Log.err (fun f -> f "Socket.UDP?.of_bound_fd: %s" msg);
          failwith msg

      let getsockname { label; fd; _ } =
        match Uwt.Udp.getsockname_exn fd with
        | Unix.ADDR_INET(iaddr, port) ->
          Ipaddr.of_string_exn (Unix.string_of_inet_addr iaddr), port
        | _ -> invalid_arg (Printf.sprintf "Socket.%s.getsockname: passed a non-TCP socket" label)

      let shutdown server =
        if not server.closed then begin
          server.closed <- true;
          let result = Uwt.Udp.close server.fd in
          if not(Uwt.Int_result.is_ok result) then begin
            Log.err (fun f -> f "Socket.%s: close returned %s" server.label (Uwt.strerror (Uwt.Int_result.to_error result)));
          end;
          deregister_connection server.idx;
        end;
        Lwt.return_unit

    let rec recvfrom server buf =
      Uwt.Udp.recv_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len ~buf:buf.Cstruct.buffer server.fd
      >>= fun recv ->
      if recv.Uwt.Udp.is_partial then begin
        Log.err (fun f -> f "Socket.%s.recvfrom: dropping partial response (buffer was %d bytes)" server.label (Cstruct.len buf));
        recvfrom server buf
      end else match recv.Uwt.Udp.sockaddr with
        | None ->
          Log.err (fun f -> f "Socket.%s.recvfrom: dropping response from unknown sockaddr" server.label);
          Lwt.fail (Failure (Printf.sprintf "Socket.%s.recvfrom unknown sender" server.label))
        | Some address ->
          begin match address with
            | Unix.ADDR_INET(ip, port) ->
              let address = Ipaddr.of_string_exn @@ Unix.string_of_inet_addr ip, port in
              Lwt.return (recv.Uwt.Udp.recv_len, address)
            | _ ->
              assert false
          end

      let listen t flow_cb =
        let rec loop () =
          Lwt.catch
            (fun () ->
              (* Allocate a fresh buffer because the packet will be processed
                 in a background thread *)
              let buffer = Cstruct.create Constants.max_udp_length in
              recvfrom t buffer
              >>= fun (n, address) ->
              let data = Cstruct.sub buffer 0 n in
              (* construct a flow with this buffer available for reading *)
              (* No new fd so no new idx *)
              let description = Printf.sprintf "udp:%s" (string_of_address address) in
              let flow = of_fd ~description ~read_buffer_size:0 ~already_read:(Some data) (sockaddr_of_address address) address t.fd in
              Lwt.async
                (fun () ->
                  Lwt.catch
                    (fun () -> flow_cb flow)
                    (fun e ->
                      Log.info (fun f -> f "Socket.%s.listen callback caught: %s"
                        t.label (Printexc.to_string e)
                      );
                      Lwt.return_unit
                    )
                );
              Lwt.return true
            ) (fun e ->
              Log.err (fun f -> f "Socket.%s.listen caught %s shutting down server"
                t.label(Printexc.to_string e)
              );
              Lwt.return false
            )
          >>= function
          | false -> Lwt.return_unit
          | true -> loop () in
        Lwt.async loop

      let sendto server (ip, port) buf =
        let sockaddr = Unix.ADDR_INET(Unix.inet_addr_of_string @@ Ipaddr.to_string ip, port) in
        Uwt.Udp.send_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len ~buf:buf.Cstruct.buffer server.fd sockaddr
    end

  end

  module Stream = struct
    module Tcp = struct
      include Common

      type address = Ipaddr.t * int

      type flow = {
        idx: int;
        label: string;
        description: string;
        fd: Uwt.Tcp.t;
        read_buffer_size: int;
        mutable read_buffer: Cstruct.t;
        mutable closed: bool;
      }

      let of_fd ~idx ~label ?(read_buffer_size = default_read_buffer_size) ~description fd =
        let read_buffer = Cstruct.create read_buffer_size in
        let closed = false in
        { idx; label; description; fd; read_buffer; read_buffer_size; closed }

      let connect ?(read_buffer_size = default_read_buffer_size) (ip, port) =
        let description = "tcp:" ^ (Ipaddr.to_string ip) ^ ":" ^ (string_of_int port) in
        register_connection description
        >>= fun idx ->
        let label, fd =
          try match ip with
            | Ipaddr.V4 _ -> "TCPv4", Uwt.Tcp.init_ipv4_exn ()
            | Ipaddr.V6 _ -> "TCPv6", Uwt.Tcp.init_ipv6_exn ()
          with e -> deregister_connection idx; raise e in
        Lwt.catch
          (fun () ->
             let sockaddr = make_sockaddr (ip, port) in
             Uwt.Tcp.connect fd ~addr:sockaddr
             >>= fun () ->
             Lwt_result.return (of_fd ~idx ~label ~read_buffer_size ~description fd)
          )
          (fun e ->
             (* FIXME(djs55): error handling *)
             deregister_connection idx;
             let _ = Uwt.Tcp.close fd in
             errorf "Socket.%s.connect %s: caught %s" label description (Printexc.to_string e)
          )
            
      let connect_to ?(read_buffer_size = default_read_buffer_size) (ip, port) timeout_s =
        let description = "tcp:" ^ (Ipaddr.to_string ip) ^ ":" ^ (string_of_int port) in
        register_connection description
        >>= fun idx ->
        let label, fd =
          try match ip with
            | Ipaddr.V4 _ -> "TCPv4", Uwt.Tcp.init_ipv4_exn ()
            | Ipaddr.V6 _ -> "TCPv6", Uwt.Tcp.init_ipv6_exn ()
          with e -> deregister_connection idx; raise e in
        Lwt.catch
          (fun () ->
             let sockaddr = make_sockaddr (ip, port) in
             let c = Uwt.Tcp.connect fd ~addr:sockaddr in
             let tmout = Uwt.Timer.sleep (int_of_float (timeout_s *. 1000.)) in
             ignore(Lwt.pick [
                (tmout >|= fun () -> ignore(Uwt.Tcp.close fd));
                (c >|= fun () -> ());
             ]);
             c >>= fun () ->
             Lwt_result.return (of_fd ~idx ~label ~read_buffer_size ~description fd)
          )
          (fun e ->
             (* FIXME(djs55): error handling *)
             deregister_connection idx;
             let _ = Uwt.Tcp.close fd in
             errorf "Socket.%s.connect %s: caught %s" label description (Printexc.to_string e)
          )
      let shutdown_read _ =
        Lwt.return ()

      let shutdown_write { label; description; fd; closed; _ } =
        try
          if not closed then Uwt.Tcp.shutdown fd else Lwt.return ()
        with
        | Uwt.Uwt_error(Uwt.ENOTCONN, _, _) -> Lwt.return ()
        | e ->
          Log.err (fun f -> f "Socket.%s.shutdown_write %s: caught %s returning Eof" label description (Printexc.to_string e));
          Lwt.return ()

      let read_into t buf =
        let rec loop buf =
          if Cstruct.len buf = 0
          then Lwt.return (`Ok ())
          else
            Uwt.Tcp.read_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len t.fd ~buf:buf.Cstruct.buffer
            >>= function
            | 0 -> Lwt.return `Eof
            | n ->
              loop (Cstruct.shift buf n) in
        loop buf

      let read t =
        (if Cstruct.len t.read_buffer = 0 then t.read_buffer <- Cstruct.create t.read_buffer_size);
        Lwt.catch
          (fun () ->
             Uwt.Tcp.read_ba ~pos:t.read_buffer.Cstruct.off ~len:t.read_buffer.Cstruct.len t.fd ~buf:t.read_buffer.Cstruct.buffer
             >>= function
             | 0 -> Lwt.return `Eof
             | n ->
               let results = Cstruct.sub t.read_buffer 0 n in
               t.read_buffer <- Cstruct.shift t.read_buffer n;
               Lwt.return (`Ok results)
          ) (function
              | Uwt.Uwt_error((Uwt.ECANCELED | Uwt.ECONNRESET), _, _) ->
                Lwt.return `Eof
              | e ->
                Log.err (fun f -> f "Socket.%s.read %s: caught %s returning Eof" t.label t.description (Printexc.to_string e));
                Lwt.return `Eof
            )

      let write t buf =
        Lwt.catch
          (fun () ->
             Uwt.Tcp.write_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len t.fd ~buf:buf.Cstruct.buffer
             >>= fun () ->
             Lwt.return (`Ok ())
          ) (function
              | Uwt.Uwt_error((Uwt.ECANCELED | Uwt.ECONNRESET), _, _) ->
                Lwt.return `Eof
              | e ->
                Log.err (fun f -> f "Socket.%s.write %s: caught %s returning Eof" t.label t.description (Printexc.to_string e));
                Lwt.return `Eof
            )

      let writev t bufs =
        Lwt.catch
          (fun () ->
             let rec loop = function
               | [] -> Lwt.return (`Ok ())
               | buf :: bufs ->
                 Uwt.Tcp.write_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len t.fd ~buf:buf.Cstruct.buffer
                 >>= fun () ->
                 loop bufs in
             loop bufs
          ) (function
              | Uwt.Uwt_error((Uwt.ECANCELED | Uwt.ECONNRESET), _, _) ->
                Lwt.return `Eof
              | e ->
                Log.err (fun f -> f "Socket.%s.writev %s: caught %s returning Eof" t.label t.description (Printexc.to_string e));
                Lwt.return `Eof
            )

      let close t =
        if not t.closed then begin
          t.closed <- true;
          (* FIXME(djs55): errors *)
          let _ = Uwt.Tcp.close t.fd in
          deregister_connection t.idx;
          Lwt.return ()
        end else Lwt.return ()

      type server = {
        label: string;
        mutable listening_fds: (int * Uwt.Tcp.t) list;
        read_buffer_size: int;
      }

      let getsockname' = function
        | [] -> failwith "Tcp.getsockname: socket is closed"
        | (_, fd) :: _ ->
          match Uwt.Tcp.getsockname_exn fd with
          | Unix.ADDR_INET(iaddr, port) ->
            Ipaddr.of_string_exn (Unix.string_of_inet_addr iaddr), port
          | _ -> invalid_arg "Tcp.getsockname passed a non-TCP socket"

      let make ?(read_buffer_size = default_read_buffer_size) listening_fds =
        let label = match getsockname' listening_fds with
          | Ipaddr.V4 _, _ -> "TCPv4"
          | Ipaddr.V6 _, _ -> "TCPv6" in
        { label; listening_fds; read_buffer_size }

      let getsockname server = getsockname' server.listening_fds

      let bind_one (ip, port) =
        let description = "tcp:" ^ (Ipaddr.to_string ip) ^ ":" ^ (string_of_int port) in
        register_connection description
        >>= fun idx ->
        let fd = try Uwt.Tcp.init () with e -> deregister_connection idx; raise e in
        let addr = make_sockaddr (ip, port) in
        let result = Uwt.Tcp.bind fd ~addr () in
        let label = match ip with
          | Ipaddr.V4 _ -> "TCPv4"
          | Ipaddr.V6 _ -> "TCPv6" in
        if not(Uwt.Int_result.is_ok result) then begin
          let error = Uwt.Int_result.to_error result in
          let msg = Printf.sprintf "Socket.%s.bind(%s, %d): %s" label (Ipaddr.to_string ip) port (Uwt.strerror error) in
          Log.err (fun f -> f "Socket.%s.bind: %s" label msg);
          deregister_connection idx;
          Lwt.fail (Unix.Unix_error(Uwt.to_unix_error error, "bind", ""))
        end else Lwt.return (idx, label, fd)

      let bind (ip, port) =
        bind_one (ip, port)
        >>= fun (idx, label, fd) ->
        ( match Uwt.Tcp.getsockname fd with
          | Uwt.Ok sockaddr ->
            begin match ip_port_of_sockaddr sockaddr with
              | Some (_, local_port) -> Lwt.return local_port
              | _ -> assert false
            end
          | Uwt.Error error ->
            let msg = Printf.sprintf "Socket.%s.bind(%s, %d): %s" label (Ipaddr.to_string ip) port (Uwt.strerror error) in
            Log.debug (fun f -> f "Socket.%s.bind: %s" label msg);
            deregister_connection idx;
            Lwt.fail (Unix.Unix_error(Uwt.to_unix_error error, "bind", "")) )
        >>= fun local_port ->
        (* On some systems localhost will resolve to ::1 first and this can
           cause performance problems (particularly on Windows). Perform a
           best-effort bind to the ::1 address. *)
        Lwt.catch
          (fun () ->
             if Ipaddr.compare ip (Ipaddr.V4 Ipaddr.V4.localhost) = 0
             || Ipaddr.compare ip (Ipaddr.V4 Ipaddr.V4.any) = 0
             then begin
               Log.debug (fun f -> f "attempting a best-effort bind of ::1:%d" local_port);
               bind_one (Ipaddr.(V6 V6.localhost), local_port)
               >>= fun (idx, _, fd) ->
               Lwt.return [ idx, fd ]
             end else begin
               Lwt.return []
             end
          ) (fun e ->
              Log.debug (fun f -> f "ignoring failed bind to ::1:%d (%s)" local_port (Printexc.to_string e));
              Lwt.return []
            )
        >>= fun extra ->
        Lwt.return (make ((idx, fd) :: extra))

      let shutdown server =
        let fds = server.listening_fds in
        server.listening_fds <- [];
        (* FIXME(djs55): errors *)
        List.iter (fun (idx, fd) ->
          ignore (Uwt.Tcp.close fd);
          deregister_connection idx
        ) fds;
        Lwt.return ()

      let of_bound_fd ?(read_buffer_size = default_read_buffer_size) fd =
        let description = match Unix.getsockname fd with
          | Unix.ADDR_INET(iaddr, port) ->
            "tcp:" ^ (Unix.string_of_inet_addr iaddr) ^ ":" ^ (string_of_int port)
          | _ -> "of_bound_fd: unknown TCP socket" in
        let fd = Uwt.Tcp.opentcp_exn fd in
        let idx = register_connection_no_limit description in
        make ~read_buffer_size [ (idx, fd) ]

      let listen server cb =
        List.iter
          (fun (_, fd) ->
             Uwt.Tcp.listen_exn fd ~max:32 ~cb:(fun server x ->
                 if Uwt.Int_result.is_error x then
                   ignore(Uwt_io.printl "listen error")
                 else
                   let client = Uwt.Tcp.init () in
                   let t = Uwt.Tcp.accept_raw ~server ~client in
                   if Uwt.Int_result.is_error t then begin
                     ignore(Uwt_io.printl "accept error");
                   end else begin
                     let label, description = match Uwt.Tcp.getpeername client with
                       | Uwt.Ok sockaddr ->
                         begin match ip_port_of_sockaddr sockaddr with
                           | Some (Some ip, port) ->
                            "tcp:" ^ (Ipaddr.to_string ip) ^ ":" ^ (string_of_int port),
                              begin match ip with
                              | Ipaddr.V4 _ -> "TCPv4"
                              | Ipaddr.V6 _ -> "TCPv6"
                              end
                           | _ -> "unknown incoming TCP", "TCP"
                         end
                       | Uwt.Error error -> "getpeername failed: " ^ (Uwt.strerror error), "TCP" in

                     Lwt.async
                       (fun () ->
                         Lwt.catch
                           (fun () ->
                             register_connection description
                             >>= fun idx ->
                             Lwt.return (Some (of_fd ~idx ~label ~description client))
                           ) (fun _e ->
                             ignore (Uwt.Tcp.close client);
                             Lwt.return_none
                           )
                         >>= function
                         | None -> Lwt.return_unit
                         | Some flow ->
                           log_exception_continue "listen"
                             (fun () ->
                                Lwt.finalize
                                  (fun () ->
                                     log_exception_continue "Socket.Stream"
                                       (fun () ->
                                         cb flow
                                       )
                                  ) (fun () -> close flow)
                             )
                      )
                   end
               );
          ) server.listening_fds

    end

    module Unix = struct
      include Common

      type address = string

      type flow = {
        idx: int;
        description: string;
        fd: Uwt.Pipe.t;
        read_buffer_size: int;
        mutable read_buffer: Cstruct.t;
        mutable closed: bool;
      }

      let of_fd ~idx ?(read_buffer_size = default_read_buffer_size) ~description fd =
        let read_buffer = Cstruct.create read_buffer_size in
        let closed = false in
        { idx; description; fd; read_buffer; read_buffer_size; closed }

      let unsafe_get_raw_fd t =
        let fd = Uwt.Pipe.fileno_exn t.fd in
        Unix.clear_nonblock fd;
        fd

      let connect ?(read_buffer_size = default_read_buffer_size) path =
        let description = "unix:" ^ path in
        register_connection description
        >>= fun idx ->
        let fd = Uwt.Pipe.init () in
        Lwt.catch
          (fun () ->
            Uwt.Pipe.connect fd ~path
            >>= fun () ->
            let description = path in
            Lwt_result.return (of_fd ~idx ~read_buffer_size ~description fd)
          ) (fun e ->
            deregister_connection idx;
            Lwt.fail e
          )

      let shutdown_read _ =
        Lwt.return ()

      let shutdown_write { description; fd; closed; _ } =
        try
          if not closed then Uwt.Pipe.shutdown fd else Lwt.return ()
        with
        | Uwt.Uwt_error(Uwt.ENOTCONN, _, _) -> Lwt.return ()
        | e ->
          Log.err (fun f -> f "Socket.Pipe.shutdown_write %s: caught %s returning Eof" description (Printexc.to_string e));
          Lwt.return ()

      let read_into t buf =
        let rec loop buf =
          if Cstruct.len buf = 0
          then Lwt.return (`Ok ())
          else
            Uwt.Pipe.read_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len t.fd ~buf:buf.Cstruct.buffer
            >>= function
            | 0 -> Lwt.return `Eof
            | n ->
              loop (Cstruct.shift buf n) in
        loop buf

      let read t =
        (if Cstruct.len t.read_buffer = 0 then t.read_buffer <- Cstruct.create t.read_buffer_size);
        Lwt.catch
          (fun () ->
             Uwt.Pipe.read_ba ~pos:t.read_buffer.Cstruct.off ~len:t.read_buffer.Cstruct.len t.fd ~buf:t.read_buffer.Cstruct.buffer
             >>= function
             | 0 -> Lwt.return `Eof
             | n ->
               let results = Cstruct.sub t.read_buffer 0 n in
               t.read_buffer <- Cstruct.shift t.read_buffer n;
               Lwt.return (`Ok results)
          ) (fun e ->
              Log.err (fun f -> f "Socket.Pipe.read %s: caught %s returning Eof" t.description (Printexc.to_string e));
              Lwt.return `Eof
            )

      let write t buf =
        Lwt.catch
          (fun () ->
             Uwt.Pipe.write_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len t.fd ~buf:buf.Cstruct.buffer
             >>= fun () ->
             Lwt.return (`Ok ())
          ) (function
             | Uwt.Uwt_error(Uwt.EPIPE, _, _) ->
               (* other end has closed, this is normal *)
               Lwt.return `Eof
             | e ->
               (* Unexpected error *)
               Log.err (fun f -> f "Socket.Pipe.write %s: caught %s returning Eof" t.description (Printexc.to_string e));
               Lwt.return `Eof
            )

      let writev t bufs =
        Lwt.catch
          (fun () ->
             let rec loop = function
               | [] -> Lwt.return (`Ok ())
               | buf :: bufs ->
                 Uwt.Pipe.write_ba ~pos:buf.Cstruct.off ~len:buf.Cstruct.len t.fd ~buf:buf.Cstruct.buffer
                 >>= fun () ->
                 loop bufs in
             loop bufs
          ) (fun e ->
              Log.err (fun f -> f "Socket.Pipe.writev %s: caught %s returning Eof" t.description (Printexc.to_string e));
              Lwt.return `Eof
            )

      let close t =
        if not t.closed then begin
          t.closed <- true;
          (* FIXME(djs55): errors *)
          let _ = Uwt.Pipe.close t.fd in
          deregister_connection t.idx;
          Lwt.return ()
        end else Lwt.return ()

      type server = {
        idx: int;
        fd: Uwt.Pipe.t;
        mutable closed: bool;
      }

      let bind path =
        Lwt.catch
          (fun () ->
             Uwt.Fs.unlink path
          ) (fun _ -> Lwt.return ())
        >>= fun () ->
        let description = "unix:" ^ path in
        register_connection description
        >>= fun idx ->
        let fd = Uwt.Pipe.init () in
        Lwt.catch
          (fun () ->
            Uwt.Pipe.bind_exn fd ~path;
            Lwt.return { idx; fd; closed = false }
          ) (fun e ->
            deregister_connection idx;
            Lwt.fail e
          )

      let getsockname server = match Uwt.Pipe.getsockname server.fd with
        | Uwt.Ok path ->
          path
        | _ -> invalid_arg "Unix.sockname passed a non-Unix socket"

      let listen ({ fd; _ } as server') cb =
        Uwt.Pipe.listen_exn fd ~max:5 ~cb:(fun server x ->
            if Uwt.Int_result.is_error x then
              ignore(Uwt_io.printl "listen error")
            else
              let client = Uwt.Pipe.init () in
              let t = Uwt.Pipe.accept_raw ~server ~client in
              if Uwt.Int_result.is_error t then begin
                ignore(Uwt_io.printl "accept error");
              end else begin
                Lwt.async
                  (fun () ->
                    Lwt.catch
                      (fun () ->
                        let description = "unix:" ^ (getsockname server') in
                        register_connection description
                        >>= fun idx ->
                        Lwt.return (Some (of_fd ~idx ~description client))
                      ) (fun _e ->
                        ignore (Uwt.Pipe.close client);
                        Lwt.return_none
                      )
                    >>= function
                    | None -> Lwt.return_unit
                    | Some flow ->
                      Lwt.finalize
                        (fun () ->
                          log_exception_continue "Pipe.listen"
                            (fun () ->
                              cb flow
                            )
                        ) (fun () -> close flow )
                  )
              end
          )

      let of_bound_fd ?(read_buffer_size = default_read_buffer_size) fd =
        match Uwt.Pipe.openpipe fd with
        | Uwt.Ok fd ->
          let description = match Uwt.Pipe.getsockname fd with
            | Uwt.Ok path -> "unix:" ^ path
            | Uwt.Error error -> "getsockname failed: " ^ (Uwt.strerror error) in
          let idx = register_connection_no_limit description in
          { idx; fd; closed = false }
        | Uwt.Error error ->
          let msg = Printf.sprintf "Socket.Pipe.of_bound_fd (read_buffer_size=%d) failed with %s" read_buffer_size (Uwt.strerror error) in
          Log.err (fun f -> f "%s" msg);
          failwith msg

      let shutdown server =
        if not server.closed then begin
          server.closed <- true;
          (* FIXME(djs55): errors *)
          ignore(Uwt.Pipe.close server.fd);
          deregister_connection server.idx;
        end;
        Lwt.return ()




    end
  end
end

module Files = struct
  let read_file path =
    let open Lwt.Infix in
    Lwt.catch
      (fun () ->
         Uwt.Fs.openfile ~mode:[ Uwt.Fs_types.O_RDONLY ] path
         >>= fun file ->
         let buffer = Buffer.create 128 in
         let frag = Bytes.make 1024 ' ' in
         Lwt.finalize
           (fun () ->
              let rec loop () =
                Uwt.Fs.read file ~buf:frag
                >>= function
                | 0 ->
                  Lwt_result.return (Buffer.contents buffer)
                | n ->
                  Buffer.add_substring buffer frag 0 n;
                  loop () in
              loop ()
           ) (fun () ->
               Uwt.Fs.close file
             )
      ) (fun e ->
          Lwt_result.fail (`Msg (Printf.sprintf "reading %s: %s" path (Printexc.to_string e)))
        )

  (* NOTE(djs55): Fs_event didn't work for me on MacOS *)
  type watch = Uwt.Fs_poll.t

  let unwatch w = Uwt.Fs_poll.close_noerr w

  let watch_file path callback =
    let cb _h res = match res with
      | Result.Ok _ ->
        callback ()
      | Result.Error err ->
        Log.err (fun f -> f "While watching %s: %s" path (Uwt.err_name err));
        () in
    match Uwt.Fs_poll.start path 5000 ~cb with
      | Result.Ok handle ->
        callback ();
        Result.Ok handle
      | Result.Error err ->
        Log.err (fun f -> f "Starting to watch %s: %s" path (Uwt.err_name err));
        Result.Error (`Msg (Uwt.strerror err))

end

module Time = struct
  type 'a io = 'a Lwt.t

  let sleep secs = Uwt.Timer.sleep (int_of_float (secs *. 1000.))
end

module Main = struct
  let run = Uwt.Main.run
  let run_in_main = Uwt_preemptive.run_in_main
end
