(* Copyright (C) 2015, Thomas Leonard
   See the README file for details. *)

(** This should be compiled and installed in dom0 as e.g. /usr/local/bin/test-mirage-dom0
    That path should also be placed in /etc/qubes-rpc/talex5.TestMirage
    and a policy allowing it added to /etc/qubes-rpc/policy/talex5.TestMirage *)

let image_path = "/var/lib/qubes/vm-kernels/mirage-qubes/vmlinuz"
let vm_name = "mirage-test"

open Lwt.Infix

let to_dev = Lwt_io.stdout
let from_dev = Lwt_io.stdin

let timeout s =
  Lwt_unix.sleep s >|= fun () -> failwith "Timeout!"

let rec copyn src dst = function
  | 0 -> Lwt.return ()
  | n ->
      Lwt_io.read ~count:(min 40960 n) src >>= function
      | "" -> failwith "Unexpected end-of-file"
      | data ->
          Lwt_io.write dst data >>= fun () ->
          copyn src dst (n - String.length data)

let receive_image () =
  Lwt_io.read_line from_dev >>= fun size ->
  let size = Utils.int_of_string size in
  Lwt_io.with_file ~flags:Unix.[O_CREAT; O_WRONLY; O_TRUNC] ~mode:Lwt_io.output image_path (fun to_img ->
    copyn from_dev to_img size
  )

let start_cmd = ("", [| "qvm-start"; vm_name |])
let stop_cmd = ("", [| "qvm-kill"; vm_name |])

let rec wait_for expected stream =
  Lwt_stream.get stream >>= function
  | None -> failwith (Printf.sprintf "End-of-stream while waiting for %S" expected)
  | Some line ->
      Lwt_io.write to_dev (line ^ "\n") >>= fun () ->
      if line = expected then Lwt.return ()
      else wait_for expected stream

let main () =
  Lwt_io.write_line to_dev "Ready" >>= fun () ->
  Lwt.pick [receive_image (); timeout 5.0] >>= fun () ->
  Lwt_io.write_line to_dev "Booting" >>= fun () ->
  Lwt_io.flush to_dev >>= fun () ->
  Unix.dup2 Unix.stdout Unix.stderr;
  Lwt_process.exec ~stdin:`Close ~stdout:`Keep ~stderr:(`FD_copy Unix.stdout) stop_cmd >>= fun _status ->
  let from_start = Lwt_process.pread_lines ~stdin:`Close ~stderr:(`FD_copy Unix.stdout) start_cmd in
  wait_for "--> Starting Qubes GUId..." from_start >>= fun () ->
  Unix.execv "/usr/bin/sudo" [| "/usr/bin/sudo"; "xl"; "console"; vm_name |]

let report_error ex =
  Lwt_io.write_line to_dev (Printexc.to_string ex) >|= fun () ->
  exit 1

let () =
  Lwt_main.run (Lwt.catch main report_error)
