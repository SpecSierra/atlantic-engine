/*
 * SPDX-License-Identifier: MPL-2.0
 * libharfbuzz-icu replacement for Sailfish OS.
 *
 * WebKit needs one function from libharfbuzz-icu: hb_icu_script_to_script(),
 * which turns an ICU script code into a HarfBuzz script tag. Sailfish OS ships
 * HarfBuzz without that library, and the build host's copy is tied to its own
 * ICU (74; the phone has 73), so it cannot be bundled.
 *
 * This is the same two-line conversion HarfBuzz itself does, against the
 * phone's libharfbuzz and libicuuc. It used to be a stub returning 0 for every
 * script, on the theory that only "shaping hints" were lost. In fact WebKit
 * hands the result to hb_buffer_set_script(), and with no script HarfBuzz
 * falls back to its default shaper: Arabic letters stop joining, Indic
 * clusters are not reordered, and the text direction derived from the script
 * is wrong for right-to-left scripts.
 */
#include <stdint.h>

typedef uint32_t hb_script_t;
typedef int UScriptCode;
#define USCRIPT_INVALID_CODE (-1)
#define HB_SCRIPT_INVALID ((hb_script_t)0)

/* libicuuc: the ISO 15924 code ("Arab", "Latn", ...) of a script. The Sailfish
 * ICU exports its symbols without a version suffix. */
extern const char* uscript_getShortName(UScriptCode script_code);
/* libharfbuzz */
extern hb_script_t hb_script_from_string(const char* str, int len);

hb_script_t hb_icu_script_to_script(UScriptCode script_code)
{
    if (script_code == USCRIPT_INVALID_CODE)
        return HB_SCRIPT_INVALID;
    return hb_script_from_string(uscript_getShortName(script_code), -1);
}
