#include <lean/lean.h>
#include <assert.h>
#include <stdint.h>
#include <string.h>

#if defined(__SSE2__)
#include <emmintrin.h>
#endif

#if defined(HASHI_GPROF)
#include <sys/gmon.h>
#endif

#define HASHI_WIDTH 8
#define HASHI_EMPTY UINT8_C(0xff)

LEAN_EXPORT lean_obj_res hashi_profile_control(uint8_t enabled) {
#if defined(HASHI_GPROF)
    moncontrol(enabled != 0);
#else
    (void)enabled;
#endif
    return lean_io_result_mk_ok(lean_box(0));
}

static inline const uint8_t *hashi_ctrl_ptr(b_lean_obj_arg ctrl, size_t pos) {
    assert(pos + HASHI_WIDTH <= lean_sarray_size(ctrl));
    return lean_sarray_cptr(ctrl) + pos;
}

LEAN_EXPORT uint32_t hashi_group_match_h2(
    b_lean_obj_arg ctrl, size_t pos, uint8_t tag) {
    const uint8_t *p = hashi_ctrl_ptr(ctrl, pos);
    uint32_t bits = 0;
    for (uint32_t i = 0; i < HASHI_WIDTH; ++i) {
        if (p[i] == tag) bits |= UINT32_C(1) << i;
    }
    return bits;
}

LEAN_EXPORT uint32_t hashi_group_match_h2_and_empty(
    b_lean_obj_arg ctrl, size_t pos, uint8_t tag) {
    const uint8_t *p = hashi_ctrl_ptr(ctrl, pos);
#if defined(__SSE2__)
    const __m128i group = _mm_loadl_epi64((const __m128i *)(const void *)p);
    const __m128i tags = _mm_set1_epi8((char)tag);
    const __m128i empty = _mm_set1_epi8((char)HASHI_EMPTY);
    const uint32_t matches =
        (uint32_t)_mm_movemask_epi8(_mm_cmpeq_epi8(group, tags)) & UINT32_C(0xff);
    const uint32_t empties =
        (uint32_t)_mm_movemask_epi8(_mm_cmpeq_epi8(group, empty)) & UINT32_C(0xff);
    return matches | (empties << HASHI_WIDTH);
#else
    uint32_t matches = 0;
    uint32_t empties = 0;
    for (uint32_t i = 0; i < HASHI_WIDTH; ++i) {
        if (p[i] == tag) matches |= UINT32_C(1) << i;
        if (p[i] == HASHI_EMPTY) empties |= UINT32_C(1) << i;
    }
    return matches | (empties << HASHI_WIDTH);
#endif
}

LEAN_EXPORT uint32_t hashi_group_match_for_insert(
    b_lean_obj_arg ctrl, size_t pos, uint8_t tag) {
    const uint8_t *p = hashi_ctrl_ptr(ctrl, pos);
#if defined(__SSE2__)
    const __m128i group = _mm_loadl_epi64((const __m128i *)(const void *)p);
    const __m128i tags = _mm_set1_epi8((char)tag);
    const __m128i empty = _mm_set1_epi8((char)HASHI_EMPTY);
    const uint32_t matches =
        (uint32_t)_mm_movemask_epi8(_mm_cmpeq_epi8(group, tags)) & UINT32_C(0xff);
    const uint32_t empties =
        (uint32_t)_mm_movemask_epi8(_mm_cmpeq_epi8(group, empty)) & UINT32_C(0xff);
    const uint32_t available =
        (uint32_t)_mm_movemask_epi8(group) & UINT32_C(0xff);
    return matches | (empties << HASHI_WIDTH) | (available << (2 * HASHI_WIDTH));
#else
    uint32_t matches = 0;
    uint32_t empties = 0;
    uint32_t available = 0;
    for (uint32_t i = 0; i < HASHI_WIDTH; ++i) {
        if (p[i] == tag) matches |= UINT32_C(1) << i;
        if (p[i] == HASHI_EMPTY) empties |= UINT32_C(1) << i;
        if ((p[i] & UINT8_C(0x80)) != 0) available |= UINT32_C(1) << i;
    }
    return matches | (empties << HASHI_WIDTH) | (available << (2 * HASHI_WIDTH));
#endif
}

LEAN_EXPORT uint32_t hashi_group_match_empty(b_lean_obj_arg ctrl, size_t pos) {
    const uint8_t *p = hashi_ctrl_ptr(ctrl, pos);
    uint32_t bits = 0;
    for (uint32_t i = 0; i < HASHI_WIDTH; ++i) {
        if (p[i] == HASHI_EMPTY) bits |= UINT32_C(1) << i;
    }
    return bits;
}

LEAN_EXPORT uint32_t hashi_group_match_empty_or_deleted(
    b_lean_obj_arg ctrl, size_t pos) {
    const uint8_t *p = hashi_ctrl_ptr(ctrl, pos);
    uint32_t bits = 0;
    for (uint32_t i = 0; i < HASHI_WIDTH; ++i) {
        if ((p[i] & UINT8_C(0x80)) != 0) bits |= UINT32_C(1) << i;
    }
    return bits;
}

LEAN_EXPORT uint8_t hashi_group_any_empty(b_lean_obj_arg ctrl, size_t pos) {
    const uint8_t *p = hashi_ctrl_ptr(ctrl, pos);
    for (uint32_t i = 0; i < HASHI_WIDTH; ++i) {
        if (p[i] == HASHI_EMPTY) return 1;
    }
    return 0;
}

LEAN_EXPORT uint32_t hashi_ctz32(uint32_t bits) {
    return bits == 0 ? 32 : (uint32_t)__builtin_ctz(bits);
}

LEAN_EXPORT lean_obj_res hashi_ctrl_alloc(size_t buckets) {
    const size_t size = buckets + HASHI_WIDTH;
    lean_object *ctrl = lean_alloc_sarray(1, size, size);
    memset(lean_sarray_cptr(ctrl), HASHI_EMPTY, size);
    return ctrl;
}

LEAN_EXPORT lean_obj_res hashi_ctrl_set(
    lean_obj_arg ctrl, size_t buckets, size_t index, uint8_t value) {
    if (buckets == 0 || index >= buckets) return ctrl;
    ctrl = lean_byte_array_uset(ctrl, index, value);
    if (index < HASHI_WIDTH) {
        ctrl = lean_byte_array_uset(ctrl, buckets + index, value);
    }
    if (buckets < HASHI_WIDTH) {
        ctrl = lean_byte_array_uset(ctrl, buckets + buckets + index, value);
    }
    return ctrl;
}
