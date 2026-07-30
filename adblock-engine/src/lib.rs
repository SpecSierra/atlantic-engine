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
    let mut engine = AdblockEngine::new_with_filter_set_no_optimize(FilterSet::new(true));
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
    http_method: *const c_char,
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
        // $method is new in adblock 0.13. An unparseable/empty method yields
        // None, and a filter carrying $method then never matches — so passing
        // the real verb is what makes those rules work at all. The caller
        // reads it from WebKitURIRequest.
        let method = str_from_c(http_method);

        if rtype.is_empty() {
            return safe_match_result();
        }

        // Request::new parses the request/source hostnames itself. The old
        // Request::preparsed call passed "" as the request HOSTNAME (and a full
        // URL where a hostname was expected), so hostname-anchored ("||host^")
        // filters could never match — device-proven with the deep_click rules:
        // engine.dat matched via Request::new but the runtime never blocked.
        // Third-party is derived from the parsed hostnames; the caller's flag
        // is only a fallback when the source URL is unparseable.
        let request = match Request::new(req, src, rtype, method) {
            Ok(r) => r,
            Err(_) => Request::preparsed(req, "", "", rtype, third_party, method),
        };

        let result = eng.check_network_request(&request);

        // 0.13 replaced the `matched` bool with Option<FilterRuleDebugInfo>
        // fields. Upstream's own definition was
        //   matched = exception.is_none() && (filter.is_some() || matched_rule)
        // and `filter` now already folds in the matched_rule fallback, so this
        // is the exact equivalent.
        MatchResult {
            matched: result.exception.is_none() && result.filter.is_some(),
            important: result.important,
            redirect: match &result.redirect {
                Some(s) => to_c_string(s),
                None => std::ptr::null_mut(),
            },
            // Was Option<String> (the filter's Display) in 0.12; now a struct
            // whose Display prepends a source location. Keep the raw rule only.
            exception: match result.exception.as_ref().and_then(|d| d.raw_line.as_deref()) {
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

/// Load scriptlet/redirect resources (Brave `adblock-resources` dist/resources.json,
/// a JSON array of Resource objects). Resources are NOT part of the serialized
/// engine cache, so this must be called after create_from_cache in every process
/// that needs `##+js(...)` scriptlets (UI cosmetics) or `redirect=` surrogates
/// (WebProcess network extension).
#[no_mangle]
pub unsafe extern "C" fn atlantic_adblock_use_resources_json(
    engine: *mut AtlanticAdblockEngine,
    data: *const u8,
    len: usize,
) -> bool {
    if engine.is_null() || data.is_null() || len == 0 {
        return false;
    }
    let bytes = slice::from_raw_parts(data, len);
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        match serde_json::from_slice::<Vec<adblock::resources::Resource>>(bytes) {
            Ok(resources) => {
                let count = resources.len();
                (*engine).engine.use_resources(resources);
                count > 0
            }
            Err(_) => false,
        }
    }));
    result.unwrap_or(false)
}

/// Generic cosmetic filtering: given the classes and ids present in the page's
/// DOM (newline-separated), return the newline-separated hide selectors from
/// GENERIC rules (`##.ad-banner` etc.), honouring the site's exceptions.
/// Complements atlantic_adblock_get_cosmetic, which only returns site-SPECIFIC
/// selectors. Free the result with atlantic_adblock_free_string.
#[no_mangle]
pub unsafe extern "C" fn atlantic_adblock_get_generic_hides(
    engine: *mut AtlanticAdblockEngine,
    url: *const c_char,
    classes: *const c_char,
    ids: *const c_char,
) -> *mut c_char {
    if engine.is_null() || url.is_null() {
        return std::ptr::null_mut();
    }
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let eng = &(*engine).engine;
        let url_str = str_from_c(url);
        let class_list: Vec<&str> = str_from_c(classes)
            .split('\n')
            .filter(|s| !s.is_empty())
            .collect();
        let id_list: Vec<&str> = str_from_c(ids)
            .split('\n')
            .filter(|s| !s.is_empty())
            .collect();
        if class_list.is_empty() && id_list.is_empty() {
            return std::ptr::null_mut();
        }
        let exceptions = eng.url_cosmetic_resources(url_str).exceptions;
        let selectors = eng.hidden_class_id_selectors(class_list, id_list, &exceptions);
        if selectors.is_empty() {
            return std::ptr::null_mut();
        }
        to_c_string(&selectors.join("\n"))
    }));
    result.unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn atlantic_adblock_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
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
