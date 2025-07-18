open Sexplib0

(* copied and slightly modified from https://bitbucket.org/khooyp/adapton.ocaml/src/main/Source/AdaptonInternal/TotalOrder.ml*)

(** Total-order maintenance data structure.

    Design based on:
        Dietz, Paul and Sleator, Daniel. "Two algorithms for maintaining order in a list." In Proceedings of the
            Nineteenth Annual ACM Symposium on Theory of Computing (STOC '87). http://dx.doi.org/10.1145/28395.28434
        Bender, Michael, et al. "Two simplified algorithms for maintaining order in a list." In Proceedings of the 10th
            Annual European Symposium on Algorithms (ESA '02). http://dx.doi.org/10.1007/3-540-45749-6_17

    Implementation based on:
        https://github.com/matthewhammer/ceal/blob/4b933a8/src/lib/runtime/totalorder.c
*)

module Order = struct
    let threshold = 1.4 (* rebalancing region threshold (inverse density) *)
    let label_bits = Sys.word_size - 2 (*use only the positive range*)
    
    (*let label_bits = 128 - 2 use only the positive range *)
    let max_label = 1 lsl (label_bits - 1) (* use only half the positive range to avoid needing to handle overflow *)
    let gap_size = max_label / label_bits (* gap between elements after rebalancing *)
    let end_label = max_label - gap_size

    (** Top layer bidirectional linked-list of the total-order data structure that provides coarse-grained ordering. *)
    type parent = { (* 5 words *)
        mutable parent_label : int;
        mutable parent_prev : parent;
        mutable parent_next : parent;
        mutable front : t;
        mutable back : t;
    }
    (** Bottom layer bidirectional linked-list of the total-order data structure that provides fine-grained ordering. *)
    and t = { (* 5 words (not including parent) *)
        mutable label : int;
        mutable parent : parent;
        mutable next : t;
        mutable prev : t;
    }

    (**/**) (* sentinel values *)
    let rec null_parent = {
        parent_label=min_int;
        parent_next=null_parent;
        parent_prev=null_parent;
        front=null;
        back=null;
    } and null = {
        label=min_int;
        parent=null_parent;
        prev=null;
        next=null;
    }
    
    let trim_string s = if (String.length s > 15) then (String.cat (String.sub s 0 ((String.length s) - 15)) "-") else s
    let sexp_of_t ts = Sexp.Atom(String.concat "," [(trim_string (string_of_int ts.parent.parent_label)) ; (trim_string (string_of_int ts.label))])
    let t_of_sexp _ = failwith("t_of_sexp not implemented")

    (**/**)

    (** Return if a total-order element is the initial element (i.e., the predecessor of what was returned by [create]). *)
    let is_initial ts = ts.label == 0 && ts.parent.parent_label == 0

    (** Return if a total-order element is valid (i.e., has not been removed). *)
    let is_valid ts = ts.label > 0 && ts.parent.parent_label >= 0

    (**/**) (* helper functions *)
    (*let neg = (lor) min_int*)
    let pos = (land) (lnot min_int)
    (*let invalidate ts =
        ts.label <- neg ts.label;
        ts.prev <- null;
        ts.next <- null*)
    (*let invalidate_parent parent =
        parent.parent_label <- neg parent.parent_label;
        let rec invalidate_ts ts = if ts != null then begin
            let next = ts.next in
            invalidate ts;
            invalidate_ts next
        end in
        invalidate_ts parent.front;
        (* help GC mark phase by cutting the object graph *)
        parent.parent_prev <- null_parent;
        parent.parent_next <- null_parent;
        parent.front <- null;
        parent.back <- null*)
    (**/**)

    (** Compare two total-order elements. *)
    let compare ts ts' =
        if ts == null || ts' == null then invalid_arg "TotalOrder.compare";
        let p = compare (pos ts.parent.parent_label) (pos ts'.parent.parent_label) in
        if p != 0 then p else compare (pos ts.label) (pos ts'.label)

    let lt ts ts' = (compare ts ts') < 0 
    let eq ts ts' = (compare ts ts') == 0
    let gt ts ts' = (compare ts ts') > 0
    let max ts ts' = if (lt ts ts') then ts' else ts

    (** Add a new total-order element after the given element. *)
    let add_next ts =
        if not (is_valid ts || is_initial ts) then invalid_arg "TotalOrder.add_next";

        let parent = ts.parent in
        let ts' = if ts.next != null then begin
            let next = ts.next in
            let ts' = { label=(ts.label + next.label) lsr 1; parent; prev=ts; next; } in
            next.prev <- ts';
            ts.next <- ts';
            ts'
        end else begin
            let ts' = { label=(ts.label + max_label) lsr 1; parent; prev=ts; next=null; } in
            ts.next <- ts';
             (* SUSPICIOUS MODIFICATION *)
            parent.back <- ts';
            ts'
        end in

        if ts.label == ts'.label then begin
            (* redistribute all elements under a parent such that they are spaced by [gap_size],
               adding new parents as necessary to accomodate the redistribution *)
            let rec rebalance label parent prev next =
                if label < end_label then begin
                    next.label <- label;
                    next.parent <- parent;
                    if next.next != null then
                        rebalance (label + gap_size) parent next next.next
                    else
                        parent.back <- next
                end else begin
                    (* add a new parent *)
                    parent.back <- prev;
                    prev.next <- null;
                    next.prev <- null;
                    let parent' = if parent.parent_next != null_parent then begin
                        let parent_next = parent.parent_next in
                        let parent' = {
                            parent_label=(parent.parent_label + parent_next.parent_label) lsr 1;
                            parent_prev=parent_next.parent_prev;
                            parent_next;
                            front=next;
                            back=next;
                        } in
                        parent_next.parent_prev <- parent';
                        parent.parent_next <- parent';
                        parent'
                    end else begin
                        let parent' = {
                            parent_label=(parent.parent_label + max_label) lsr 1;
                            parent_prev=parent;
                            parent_next=null_parent;
                            front=next;
                            back=next;
                        } in
                        parent.parent_next <- parent';
                        parent'
                    end in

                    if parent.parent_label == parent'.parent_label then begin
                        (* identify a region around the parent that satisfies the rebalancing threshold *)
                        let rec expand lower upper count mask tau =
                            assert(mask > 0);
                            let lo_label = lower.parent_label land (lnot mask) in
                            let hi_label = lower.parent_label lor mask in
                            let rec expand_lower lower count = if lower.parent_prev != null_parent then
                                let lower' = lower.parent_prev in
                                if lower'.parent_label >= lo_label then
                                    expand_lower lower' (count + 1)
                                else
                                    ( lower, count )
                            else begin
                                if lower.parent_label != lo_label then
                                    lower.parent_label <- lo_label;
                                ( lower, count )
                            end in
                            let rec expand_upper upper count = if upper.parent_next != null_parent then
                                let upper' = upper.parent_next in
                                if upper'.parent_label <= hi_label then
                                    expand_upper upper' (count + 1)
                                else
                                    ( upper, count )
                            else begin
                                if upper.parent_label != hi_label then
                                    upper.parent_label <- hi_label;
                                ( upper, count )
                            end in
                            let lower, count = expand_lower lower count in
                            let upper, count = expand_upper upper count in
                            if tau < float_of_int count /. float_of_int (mask + 1) then
                                expand lower upper count ((mask lsl 1) lor 1) (tau /. threshold)
                            else
                                ( lower, upper, lo_label, (mask + 1) / count )
                        in
                        let lower, upper, label, delta = expand parent parent' 2 1 (1. /. threshold) in
                        assert(delta != 0);
                        (* evenly redistribute the parents in the region *)
                        let rec rebalance parent label =
                            parent.parent_label <- label;
                            if parent != upper && parent.parent_next != null_parent then
                                rebalance parent.parent_next (label + delta)
                        in
                        rebalance lower label
                    end;
                    rebalance (if parent'.parent_label == 0 then 0 else 1) parent' next next
                end
            in
            rebalance (if parent.parent_label == 0 then 0 else 1) parent parent.front parent.front
        end;
        ts'

    
    (** Create a new total order and return its initial element. *)
    let create () = begin 
        let rec first_ts = {
            label=0;
            parent={
                parent_label=0;
                parent_next=null_parent;
                parent_prev=null_parent;
                front=first_ts;
                back=first_ts;
            };
            prev=null;
            next=null;
        } in
        add_next(first_ts) 
    end

    let add_prev ts = begin 
        let ts_prev = if ts.prev != null then ts.prev else (
            assert(ts.parent.parent_prev != null_parent);
            ts.parent.parent_prev.back 
         ) in 
        add_next ts_prev
    end

    (** Splice two elements [ts] and [ts'] in a total-order such that, [ts] is immediately followed by [ts'], removing all elements between them;
        optionally, if [inclusive] is [true], [ts] and [ts'] will also be removed. *)
    (*let splice ?(inclusive=false) ts ts' =
        if compare ts ts' > 0 then invalid_arg "TotalOrder.splice";

        if ts.parent != ts'.parent then begin
            (* invalidate all parents between ts and ts' *)
            let rec invalidate_next parent =
                if parent == ts'.parent then
                    ()
                else if parent != null_parent then begin
                    let next = parent.parent_next in
                    invalidate_parent parent;
                    invalidate_next next
                end else
                    failwith "splice"
            in
            invalidate_next ts.parent.parent_next;
            ts'.parent.parent_prev <- ts.parent;
            ts.parent.parent_next <- ts'.parent;
            ts'.parent.front <- ts';
            ts.parent.back <- ts;

            (* invalidate all elements before ts' under the same parent *)
            let rec invalidate_prev ts = if ts != null then begin
                let prev = ts.prev in
                invalidate ts;
                invalidate_prev prev
            end in
            invalidate_prev ts'.prev;
            ts'.prev <- null;

            (* invalidate all elements after ts under the same parent *)
            let rec invalidate_next ts = if ts != null then begin
                let next = ts.next in
                invalidate ts;
                invalidate_next next
            end in
            invalidate_next ts.next;
            ts.next <- null
        end else if ts != ts' then begin
            (* invalidate all elements between ts and ts' *)
            let rec invalidate_next ts =
                if ts == ts' then
                    ()
                else if ts != null then begin
                    let next = ts.next in
                    invalidate ts;
                    invalidate_next next
                end else
                    failwith "splice"
            in
            invalidate_next ts.next;
            ts'.prev <- ts;
            ts.next <- ts'
        end;

        if inclusive then begin
            let remove ts =
                if ts.prev == null then begin
                    if ts.next == null then begin
                        if ts.parent.parent_next != null_parent then
                            ts.parent.parent_next.parent_prev <- ts.parent.parent_prev;
                        if ts.parent.parent_prev != null_parent then
                            ts.parent.parent_prev.parent_next <- ts.parent.parent_next;
                        invalidate_parent ts.parent
                    end else begin
                        ts.next.prev <- null;
                        ts.parent.front <- ts.next;
                        invalidate ts
                    end
                end else begin
                    if ts.next == null then begin
                        ts.prev.next <- null;
                        ts.parent.back <- ts.prev;
                        invalidate ts
                    end else begin
                        ts.prev.next <- ts.next;
                        ts.next.prev <- ts.prev;
                        invalidate ts
                    end
                end
            in
            if not (is_initial ts) then remove ts;
            if ts' != ts then remove ts'
        end*)

end