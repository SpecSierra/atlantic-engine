use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::slice;

use adblock::engine::Engine as AdblockEngine;
use adblock::lists::FilterSet;
use adblock::request::Request;

pub struct AtlanticAdblockEngine {
    engine: AdblockEngine,
}

#[repr(C)]
pub struct MatchResult {
    pub matched: bool,
    pub important: bool,
    pub redirect: *mut c_char,
    pub exception: *mut c_char,
}

#[repr(C)]
pub struct CosmeticResult {
    pub hide_selectors: *const c_char,
    pub injected_script: *const c_char,
    pub generated_css: *const c_char,
}

fn to_c_string(s: &str) -> *mut c_char {
    CString::new(s)
        .unwrap_or_else(|_| CString::new("").unwrap())
        .into_raw()
}

unsafe fn str_from_c<'a>(ptr: *const c_char) -> &'a str {
    if ptr.is_null() {
        return "";
    }
    CStr::from_ptr(ptr).to_str().unwrap_or("")
}

fn safe_match_result() -> MatchResult {
    MatchResult {
        matched: false,
        important: false,
        redirect: std::ptr::null_mut(),
        exception: std::ptr::null_mut(),
    }
}

fn safe_cosmetic_result() -> CosmeticResult {
    CosmeticResult {
        hide_selectors: std::ptr::null(),
        injected_script: std::ptr::null(),
        generated_css: std::ptr::null(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn atlantic_adblock_create_from_cache(
    data: *const u8,
    len: usize,
) -> *mut AtlanticAdblockEngine {
    if data.is_null() || len == 0 {
        return std::ptr::null_mut();
    }
    let bytes = slice::from_raw_parts(data, len);
    let mut engine = AdblockEngine::from_filter_set(FilterSet::new(true), false);
    match engine.deserialize(bytes) {
        Ok(()) => Box::into_raw(Box::new(AtlanticAdblockEngine { engine })),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn atlantic_adblock_destroy(engine: *mut AtlanticAdblockEngine) {
    if !engine.is_null() {
        drop(Box::from_raw(engine));
    }
}

#[no_mangle]
pub unsafe extern "C" fn atlantic_adblock_match_network(
    engine: *mut AtlanticAdblockEngine,
    src_url: *const c_char,
    req_url: *const c_char,
    resource_type: *const c_char,
    third_party_raw: i32,
) -> MatchResult {
    if engine.is_null() || req_url.is_null() {
        return safe_match_result();
    }

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let eng = &(*engine).engine;
        let src = str_from_c(src_url);
        let req = str_from_c(req_url);
        let rtype = str_from_c(resource_type);
        let third_party = third_party_raw != 0;

        if rtype.is_empty() {
            return safe_match_result();
        }

        let request = Request::preparsed(
            req,
            "",
            if src.is_empty() || third_party { "" } else { src },
            rtype,
            third_party,
        );

        let result = eng.check_network_request(&request);

        MatchResult {
            matched: result.matched,
            important: result.important,
            redirect: match &result.redirect {
                Some(s) => to_c_string(s),
                None => std::ptr::null_mut(),
            },
            exception: match &result.exception {
                Some(s) => to_c_string(s),
                None => std::ptr::null_mut(),
            },
        }
    }));

    result.unwrap_or_else(|_| safe_match_result())
}

#[no_mangle]
pub unsafe extern "C" fn atlantic_adblock_free_match_result(result: MatchResult) {
    if !result.redirect.is_null() {
        drop(CString::from_raw(result.redirect));
    }
    if !result.exception.is_null() {
        drop(CString::from_raw(result.exception));
    }
}

#[no_mangle]
pub unsafe extern "C" fn atlantic_adblock_get_cosmetic(
    engine: *mut AtlanticAdblockEngine,
    url: *const c_char,
) -> CosmeticResult {
    if engine.is_null() || url.is_null() {
        return safe_cosmetic_result();
    }

    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let eng = &(*engine).engine;
        let url_str = str_from_c(url);

        let resources = eng.url_cosmetic_resources(url_str);

        let hide = if resources.hide_selectors.is_empty() {
            std::ptr::null()
        } else {
            let combined: Vec<&str> = resources.hide_selectors.iter().map(|s| s.as_str()).collect();
            // Newline-separated: selectors can legitimately contain commas
            // (":is(a, b)", attribute values), so a comma join cannot be split
            // back apart by the consumer. The C++ side emits one CSS rule per
            // line so an invalid selector only invalidates its own rule.
            let joined = combined.join("\n");
            // to_c_string tolerates interior NUL bytes (downloaded filter lists are
            // untrusted); CString::new().unwrap() here would panic instead.
            to_c_string(&joined) as *const c_char
        };

        let script = if resources.injected_script.is_empty() {
            std::ptr::null()
        } else {
            to_c_string(resources.injected_script.as_str()) as *const c_char
        };

        let css = if resources.procedural_actions.is_empty() {
            std::ptr::null()
        } else {
            let combined: Vec<&str> = resources.procedural_actions.iter().map(|s| s.as_str()).collect();
            let joined = combined.join("\n");
            to_c_string(&joined) as *const c_char
        };

        CosmeticResult {
            hide_selectors: hide,
            injected_script: script,
            generated_css: css,
        }
    }));

    result.unwrap_or_else(|_| safe_cosmetic_result())
}

#[no_mangle]
pub unsafe extern "C" fn atlantic_adblock_free_cosmetic(result: CosmeticResult) {
    if !result.hide_selectors.is_null() {
        drop(CString::from_raw(result.hide_selectors as *mut c_char));
    }
    if !result.injected_script.is_null() {
        drop(CString::from_raw(result.injected_script as *mut c_char));
    }
    if !result.generated_css.is_null() {
        drop(CString::from_raw(result.generated_css as *mut c_char));
    }
}
