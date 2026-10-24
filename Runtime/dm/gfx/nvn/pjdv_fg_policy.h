#ifndef PJDV_FG_POLICY_H
#define PJDV_FG_POLICY_H
// 0 native, 1 source30/display60, 2 source60/display120.
// Mode 2 must never halve the original 60Hz game cadence.
static inline int pjdv_fg_source_hz(int mode) { return mode == 1 ? 30 : 60; }
static inline int pjdv_fg_output_hz(int mode) { return mode == 2 ? 120 : 60; }
static inline int pjdv_fg_link_mode(int mode) { return mode == 2 ? 2 : 1; }
#endif
