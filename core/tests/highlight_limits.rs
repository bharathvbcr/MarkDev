use std::ptr;

use markdev::ffi::{md_highlight, md_highlight_free, md_highlight_supports};

const MAX_CODE_BYTES: usize = 1024 * 1024;
const MAX_LANGUAGE_BYTES: usize = 64;

#[test]
fn highlight_accepts_exactly_the_code_limit_and_rejects_plus_one() {
    let language = b"rust";
    let exact = vec![b' '; MAX_CODE_BYTES];
    let accepted = unsafe {
        md_highlight(
            language.as_ptr(),
            language.len(),
            exact.as_ptr(),
            exact.len(),
        )
    };
    assert!(!accepted.is_null());
    unsafe { md_highlight_free(accepted) };

    let oversized = vec![b' '; MAX_CODE_BYTES + 1];
    let rejected = unsafe {
        md_highlight(
            language.as_ptr(),
            language.len(),
            oversized.as_ptr(),
            oversized.len(),
        )
    };
    assert!(
        rejected.is_null(),
        "a +1 code block must not reach tree-sitter"
    );
}

#[test]
fn highlight_rejects_invalid_pointer_length_pairs() {
    let language = b"rust";
    assert!(unsafe { md_highlight(language.as_ptr(), language.len(), ptr::null(), 1) }.is_null());
    assert!(unsafe { md_highlight(ptr::null(), 1, ptr::null(), 0) }.is_null());

    let empty_language = unsafe { md_highlight(ptr::null(), 0, ptr::null(), 0) };
    assert!(!empty_language.is_null());
    unsafe { md_highlight_free(empty_language) };
}

#[test]
fn language_lookup_is_bounded_before_normalization() {
    let exact = [b'r'; MAX_LANGUAGE_BYTES];
    assert_eq!(
        unsafe { md_highlight_supports(exact.as_ptr(), exact.len()) },
        0
    );

    let padded_supported = format!("rust{}", " ".repeat(MAX_LANGUAGE_BYTES - 3));
    assert_eq!(padded_supported.len(), MAX_LANGUAGE_BYTES + 1);
    assert_eq!(
        unsafe { md_highlight_supports(padded_supported.as_ptr(), padded_supported.len()) },
        0,
        "normalization must not turn an oversized key into an accepted one"
    );

    assert_eq!(unsafe { md_highlight_supports(ptr::null(), 0) }, 0);
    assert_eq!(unsafe { md_highlight_supports(ptr::null(), 1) }, 0);
}
