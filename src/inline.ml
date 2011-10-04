open Ir
open List
open Map
open Analysis
open Ir
open Printf
open Ir_printer

(* Generate a unique name for each call site *)
let name_counter = ref 0 
let mkname () = name_counter := (!name_counter)+1; string_of_int (!name_counter)

(* inline everything - replace all calls with inlined versions of the function in question *)
let rec inline_stmt (stmt : stmt) (env : environment) =
  (* Transform a statement using each call provided *)
  let rec xform stmt (calls : (string * val_type * (expr list)) list) = 
    (* TODO: factor this out into the subsitution part and the enclose part *)
    begin match calls with
      | (name, ty, args) :: rest ->
        let tmpname = "C" ^ (mkname ()) ^ "_" in
        (* Lookup the function type signature and body in the environment *)
        let (_, typed_argnames, t, f_body) = Environment.find name env in
        let argnames = List.map fst typed_argnames in
        printf "argnames: %s\n" (String.concat ", " argnames);
        begin match f_body with 

          | Impure f_body ->            
            printf "body: %s\n" (string_of_stmt f_body);
            (* prefix body var names with callsite prefix to prevent nonsense when inserting arguments *)        
            let prefixed = List.fold_left (fun s x -> subs_name_stmt x (tmpname ^ x) s) f_body argnames in
            printf "prefixed: %s\n" (string_of_stmt prefixed);
            (* subs body var names for args *)
            let substituted = List.fold_left2 (fun s x e -> subs_stmt (Var (i32, tmpname ^ x)) e s) prefixed argnames args in
            printf "substituted: %s\n" (string_of_stmt substituted);
            (* subs tmpname for result *)
            let result = subs_name_stmt "result" (tmpname ^ "result") substituted in
            printf "result renamed: %s\n%!" (string_of_stmt result); 
            (* Recursively precompute the rest of the calls *)
            let recurse = xform stmt rest in
            (* Replace the call to this function in the current expressions with a load *)          
            let newstmt = subs_stmt (Call (name, ty, args)) (Load (ty, tmpname ^ "result", IntImm 0)) recurse in
            (* Return the statement wrapped in a pipeline *)
            Pipeline(tmpname ^ "result", ty, IntImm 1, inline_stmt result env, newstmt)

          | Pure f_body -> 
            let prefixed = List.fold_left (fun e name -> subs_name_expr name (tmpname ^ name) e) f_body argnames in
            let bound = List.fold_left2 (fun e name v -> Let (tmpname ^ name, v, e)) prefixed argnames args in
            printf "Bound body of %s: %s\n" name (string_of_expr bound);
            printf "  Found %d calls\n" (List.length (find_calls_in_expr bound));
            let newstmt = subs_stmt (Call (name, ty, args)) bound stmt in
            printf "  stmt: %s\n  newstmt: %s\n" (string_of_stmt stmt) (string_of_stmt newstmt);
            let res = xform newstmt (find_calls_in_stmt newstmt) in
            printf "inlined version of %s: %s\n" name (string_of_stmt res);
            res
        end
      | [] -> stmt
    end
  in 

  match stmt with 
    | For (name, min, n, order, body) -> 
      let newbody = inline_stmt body env in
      let calls = (find_calls_in_expr min) @ (find_calls_in_expr n) in
      xform (For(name, min, n, order, newbody)) calls
    | Store (e, buf, idx) ->
      let calls = (find_calls_in_expr e) @ (find_calls_in_expr idx) in
      xform stmt calls
    | Block l -> Block (List.map (fun x -> inline_stmt x env) l)
    | Pipeline (name, ty, size, produce, consume) ->
      let newproduce = inline_stmt produce env in
      let newconsume = inline_stmt consume env in
      let calls = find_calls_in_expr size in
      xform (Pipeline(name, ty, size, newproduce, newconsume)) calls

and find_calls_in_stmt = function 
  | For (var, min, n, order, body) -> 
    (find_calls_in_expr min) @ (find_calls_in_expr n) @ (find_calls_in_stmt body)
  | Store (v, buf, idx) -> 
    (find_calls_in_expr v) @ (find_calls_in_expr idx)
  | Block l -> 
    List.concat (List.map find_calls_in_stmt l)
  | Pipeline (name, ty, size, produce, consume) -> 
    (find_calls_in_expr size) @ (find_calls_in_stmt produce) @ (find_calls_in_stmt consume)  

and find_calls_in_expr = function
  | Call (name, ty, args) -> 
    (name, ty, args) :: (List.concat (List.map find_calls_in_expr args))
  | Cast (_, a) | Not a | Load (_, _, a) | Broadcast (a, _) ->
    find_calls_in_expr a
  | Bop (_, a, b) | Cmp(_, a, b) | And (a, b) | Or (a, b) | ExtractElement (a, b) | Ramp (a, b, _) ->
    (find_calls_in_expr a) @ (find_calls_in_expr b)
  | Select (c, a, b) -> 
    (find_calls_in_expr c) @ (find_calls_in_expr a) @ (find_calls_in_expr b)
  | MakeVector l ->
    List.concat (List.map find_calls_in_expr l)        
  | Let (n, a, b) ->
    (find_calls_in_expr a) @ (find_calls_in_expr b)
  | x -> []


  
  
