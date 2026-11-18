//! lyk's sticky plus: a keymux mod (a plugin that reads no words, see keymux's
//! `docs/plugins/README.md`). Hold the join key `+` and every stroke goes as its other keys come
//! up, `+` part of each: `THAS`, then hold `+` and strike `EUFG`, `TPHAL`, ... as long as you like,
//! one joined stroke each, without striking `+` again. Letting go of `+` on its own sends nothing.
//!
//! keymux has no notion of a sticky key; it asks this mod, each time a key comes up with others
//! still down, whether to send the stroke now (`send_early`). `deploy` copies this file into the
//! keymux steno folder as it is; `+` is lyk's one extra key, stroke bit 23 (`extra_keys: ['+']`).
//! See `site/reference/join-key.json`.

/// The join key `+`'s stroke bit.
const PLUS: i64 = 1 << 23;

/// Send the stroke now when `+` is the only key left down and the stroke has more than `+`.
#[unsafe(no_mangle)]
pub extern "C" fn send_early(held: i64, stroke: i64) -> i32 {
    i32::from(held == PLUS && stroke & !PLUS != 0)
}
