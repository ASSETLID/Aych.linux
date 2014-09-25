module Attr = struct
  type flag =
    | Disabled [@value 1] (** off by default *)
    | Inherit [@value 2] (** children inherit it *)
    | Exclude_user [@value 4] (** don't count user *)
    | Exclude_kernel [@value 8] (** don't count kernel *)
    | Exclude_hv [@value 16] (** don't count hypervisor *)
    | Exclude_idle [@value 32] (** don't count when idle *)
    | Enable_on_exec [@value 64] (** next exec enables *)
        [@@deriving Enum]

  type kind =
    (** Hardware *)
    | Cycles
    | Instructions
    | Cache_references
    | Cache_misses
    | Branch_instructions
    | Branch_misses
    | Bus_cycles
    | Stalled_cycles_frontend
    | Stalled_cycles_backend
    | Ref_cpu_cycles

    (** Software *)
    | Cpu_clock
    | Task_clock
    | Page_faults
    | Context_switches
    | Cpu_migrations
    | Page_faults_min
    | Page_faults_maj
    | Alignment_faults
    | Emulation_faults
    | Dummy
        [@@deriving Enum]

  let sexp_of_kind k =
    let open Sexplib.Sexp in
    match k with
    | Cycles -> Atom "Cycles"
    | Instructions -> Atom "Instructions"
    | Cache_references -> Atom "Cache_references"
    | Cache_misses -> Atom "Cache_misses"
    | Branch_instructions -> Atom "Branch_instructions"
    | Branch_misses -> Atom "Branch_misses"
    | Bus_cycles -> Atom "Bus_cycles"
    | Stalled_cycles_frontend -> Atom "Stalled_cycles_frontend"
    | Stalled_cycles_backend -> Atom "Stalled_cycles_backend"
    | Ref_cpu_cycles -> Atom "Ref_cpu_cycles"

    (** Software *)
    | Cpu_clock -> Atom "Cpu_clock"
    | Task_clock -> Atom "Task_clock"
    | Page_faults -> Atom "Page_faults"
    | Context_switches -> Atom "Context_switches"
    | Cpu_migrations -> Atom "Cpu_migrations"
    | Page_faults_min -> Atom "Page_faults_min"
    | Page_faults_maj -> Atom "Page_faults_maj"
    | Alignment_faults -> Atom "Alignment_faults"
    | Emulation_faults -> Atom "Emulation_faults"
    | Dummy -> Atom "Dummy"

  let kind_of_sexp s =
    let open Sexplib.Sexp in
    match s with
    | Atom "Cycles" -> Cycles
    | Atom "Instructions" -> Instructions
    | Atom "Cache_references" -> Cache_references
    | Atom "Cache_misses" -> Cache_misses
    | Atom "Branch_instructions" -> Branch_instructions
    | Atom "Branch_misses" -> Branch_misses
    | Atom "Bus_cycles" -> Bus_cycles
    | Atom "Stalled_cycles_frontend" -> Stalled_cycles_frontend
    | Atom "Stalled_cycles_backend" -> Stalled_cycles_backend
    | Atom "Ref_cpu_cycles" -> Ref_cpu_cycles

    (** Software *)
    | Atom "Cpu_clock" -> Cpu_clock
    | Atom "Task_clock" -> Task_clock
    | Atom "Page_faults" -> Page_faults
    | Atom "Context_switches" -> Context_switches
    | Atom "Cpu_migrations" -> Cpu_migrations
    | Atom "Page_faults_min" -> Page_faults_min
    | Atom "Page_faults_maj" -> Page_faults_maj
    | Atom "Alignment_faults" -> Alignment_faults
    | Atom "Emulation_faults" -> Emulation_faults
    | Atom "Dummy" -> Dummy
    | _ -> invalid_arg "kind_of_sexp"

  type t = {
    flags: flag list;
    kind: kind
  }
  (** Opaque type of a perf event attribute. *)

  let make ?(flags=[]) kind = { flags; kind; }
  (** [make ?flags kind] is a perf event attribute of type [kind],
      with flags [flags]. *)
end

type flag =
  | Fd_cloexec [@value 1]
  | Fd_no_group [@value 2]
  | Fd_output [@value 4]
  | Pid_cgroup [@value 8]
      [@@deriving Enum]

type t = {
  fd: Unix.file_descr;
  kind: Attr.kind;
}

external perf_event_open : int -> int -> int -> int -> int ->
  int -> Unix.file_descr = "stub_perf_event_open_byte" "stub_perf_event_open"
external perf_event_ioc_enable : Unix.file_descr -> unit = "perf_event_ioc_enable"
external perf_event_ioc_disable : Unix.file_descr -> unit = "perf_event_ioc_disable"
external perf_event_ioc_reset : Unix.file_descr -> unit = "perf_event_ioc_reset"

external enable_all : unit -> unit = "perf_events_enable_all"
external disable_all : unit -> unit = "perf_events_disable_all"

module FlagSet = Set.Make(struct type t = flag let compare = compare end)
module AttrFlagSet = Set.Make(struct type t = Attr.flag let compare = compare end)

let make ?(pid = 0) ?(cpu = -1) ?group ?(flags = []) attr =
  let flags = FlagSet.(of_list flags |> elements) in
  let flags = List.fold_left (fun acc f -> acc + flag_to_enum f) 0 flags in

  let attr_flags = AttrFlagSet.(of_list attr.Attr.flags |> elements) in
  let attr_flags = List.fold_left
      Attr.(fun acc f -> acc + Attr.(flag_to_enum f)) 0 attr_flags in

  let group = match group with
    | None -> -1
    | Some { fd; _ } -> (Obj.magic fd : int) in
  let kind_enum = Attr.(kind_to_enum attr.kind) in
  Attr.{ fd = perf_event_open kind_enum attr_flags pid cpu group flags;
         kind = attr.kind;
       }

let kind c = c.kind

let read c =
  let buf = Bytes.create 8 in
  let nb_read = Unix.read c.fd buf 0 8 in
  assert (nb_read = 8);
  EndianBytes.LittleEndian.get_int64 buf 0

let reset c = perf_event_ioc_reset c.fd
let enable c = perf_event_ioc_enable c.fd
let disable c = perf_event_ioc_disable c.fd

type execution = {
  process_status: Unix.process_status;
  stdout: string;
  stderr: string;
  data: (Attr.kind * int64) list;
}

let string_of_ic ic = really_input_string ic @@ in_channel_length ic

let string_of_file filename =
  let ic = open_in filename in
  try
    let res = string_of_ic ic in close_in ic; res
  with exn ->
    close_in ic; raise exn


let with_process_exn ?env ?timeout cmd attrs =
  let attrs = List.map Attr.(fun a ->
      { flags = [Disabled; Inherit; Enable_on_exec] @ a.flags;
        kind = a.kind
      }) attrs in
  let counters = List.map make attrs in
  let tmp_stdout_name = Filename.temp_file "ocaml-perf" "stdout" in
  let tmp_stderr_name = Filename.temp_file "ocaml-perf" "stderr" in
  let tmp_stdout =
    Unix.(openfile tmp_stdout_name [O_WRONLY; O_CREAT; O_TRUNC] 0o600) in
  let tmp_stderr =
    Unix.(openfile tmp_stderr_name [O_WRONLY; O_CREAT; O_TRUNC] 0o600) in
  match Unix.fork () with
  | 0 ->
      (* child *)
      Unix.(dup2 tmp_stdout stdout; close tmp_stdout);
      Unix.(dup2 tmp_stderr stderr; close tmp_stderr);
      (match env with
         | None -> Unix.execvp (List.hd cmd) (Array.of_list cmd)
         | Some env -> Unix.execvpe (List.hd cmd)
                         (Array.of_list cmd) (Array.of_list env))
  | n ->
      (* parent *)
      (* Setup an alarm if timeout is specified. The alarm signal
         handles do nothing, but this will make waitpid fail with
         EINTR, unblocking the program. *)
      let (_:int) = match timeout with None -> 0 | Some t -> Unix.alarm t in
      Sys.(set_signal sigalrm (Signal_handle (fun _ -> ())));
      let _, process_status = Unix.waitpid [] n in
      List.iter disable counters;
      Unix.(close tmp_stdout; close tmp_stderr);
      let res =
        {
          process_status;
          stdout = string_of_file tmp_stdout_name;
          stderr = string_of_file tmp_stderr_name;
          data = List.map (fun c -> c.kind, read c) counters;
        }
      in
      Unix.(unlink tmp_stdout_name; unlink tmp_stderr_name);
      res

let with_process ?env ?timeout cmd attrs =
  try `Ok (with_process_exn ?env ?timeout cmd attrs)
  with
  | Unix.Unix_error (Unix.EINTR, _, _) -> `Timeout
  | exn -> `Exn exn
