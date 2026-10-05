# Invariants

- The scanner cursor and value start stay within the complete input. A prepared
  token agrees with its value span. The container stack contains only unmatched
  containers; inline and overflow stack sizes together equal stack height.
- JSON strings contain valid Unicode scalar values before UTF-8 encoding.
  Fixed escaping buffers hold the maximum expansion of one byte or scalar.
- Decode cursors stay within input. Successful complete decoding consumes all
  input except JSON whitespace. A decoded struct has every required field set.
- Encoding buffer end never exceeds capacity. Transferring owned bytes clears
  the old buffer; failed allocation is distinct from a writer hook failure.
- Forward line offsets and numbers advance together. Borrowed line bytes and
  parsed allocations last only until the next read or deinit. Pretty scanning
  resumes after reallocations with its cursor within the rebuilt record.
- Tail end is within its block buffer. A loaded block covers [lo, lo + len),
  reverse reads move towards zero, and exhausted means no earlier record exists.
- Follower owns only handles it opened. A checkpoint binds position to identity;
  rotation resets the reader before advancing the rotation count. Waiting and
  cancellation cannot publish a torn record.
- Writer count advances only for completed records. Bounded encoding publishes
  nothing on failure or oversize. Per-record intervals are positive; sync
  failure is sticky and forbids subsequent records.
- Versioned envelopes retain the source version, and successful migration yields
  the current schema. Every written envelope carries that schema's version.
