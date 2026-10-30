//! Opt-in local corpus QA. Never edits input files or embeds user documents.
use rhwp_core::DocumentCore;
use serde_json::json;

#[test]
#[ignore = "requires DOCNOTE_COMPAT_INPUT and DOCNOTE_COMPAT_OUTPUT directories"]
fn corpus_body_text_stays_inside_paper() {
    use rhwp_core::renderer::render_tree::{RenderNode, RenderNodeType};
    fn inspect(
        node: &RenderNode,
        page_height: f64,
        page: u32,
        issues: &mut Vec<serde_json::Value>,
    ) {
        if let RenderNodeType::TextRun(text) = &node.node_type {
            if text.cell_context.is_none()
                && text.para_index.is_some()
                && !text.text.trim().is_empty()
                && (node.bbox.y < -1.0 || node.bbox.y + node.bbox.height > page_height + 1.0)
            {
                issues.push(json!({"pageZeroBased": page, "paragraph": text.para_index,
                    "y": node.bbox.y, "height": node.bbox.height, "paperHeight": page_height}));
            }
        }
        for child in &node.children {
            inspect(child, page_height, page, issues);
        }
    }
    let input = std::path::PathBuf::from(std::env::var("DOCNOTE_COMPAT_INPUT").unwrap());
    let output = std::path::PathBuf::from(std::env::var("DOCNOTE_COMPAT_OUTPUT").unwrap());
    assert_ne!(
        input.canonicalize().unwrap(),
        output.canonicalize().unwrap()
    );
    let mut reports = Vec::new();
    let mut total = 0;
    for entry in std::fs::read_dir(input).unwrap() {
        let path = entry.unwrap().path();
        if !matches!(
            path.extension().and_then(|s| s.to_str()),
            Some("hwp" | "hwpx")
        ) {
            continue;
        }
        let core = DocumentCore::from_bytes(&std::fs::read(&path).unwrap()).unwrap();
        let mut issues = Vec::new();
        for page in 0..core.page_count() {
            let tree = core.build_page_render_tree(page).unwrap();
            inspect(&tree.root, tree.root.bbox.height, page, &mut issues);
        }
        total += issues.len();
        if !issues.is_empty() {
            let paragraphs: Vec<_> = core
                .document()
                .sections
                .iter()
                .map(|s| &s.paragraphs)
                .collect();
            std::fs::write(
                output.join(format!(
                    "{}-paragraphs.json",
                    path.file_stem().unwrap().to_str().unwrap()
                )),
                serde_json::to_vec(&paragraphs).unwrap(),
            )
            .unwrap();
        }
        reports.push(
            json!({"sample": path.file_name().unwrap().to_str().unwrap(),
            "pagesChecked": core.page_count(), "outsidePaper": issues}),
        );
    }
    assert!(!reports.is_empty());
    std::fs::write(
        output.join("paper-bounds.json"),
        serde_json::to_vec_pretty(&reports).unwrap(),
    )
    .unwrap();
    assert_eq!(
        total, 0,
        "Body text outside paper; see paper-bounds.json (release gate)"
    );
}

#[test]
#[ignore = "requires DOCNOTE_COMPAT_INPUT and DOCNOTE_COMPAT_OUTPUT directories"]
fn corpus_roundtrip_and_render_samples() {
    let input = std::path::PathBuf::from(std::env::var("DOCNOTE_COMPAT_INPUT").unwrap());
    let output = std::path::PathBuf::from(std::env::var("DOCNOTE_COMPAT_OUTPUT").unwrap());
    assert_ne!(
        input.canonicalize().unwrap(),
        output.canonicalize().unwrap()
    );
    let mut paths: Vec<_> = std::fs::read_dir(input)
        .unwrap()
        .map(|p| p.unwrap().path())
        .filter(|p| matches!(p.extension().and_then(|s| s.to_str()), Some("hwp" | "hwpx")))
        .collect();
    paths.sort();
    assert!(!paths.is_empty());
    let mut results = Vec::new();
    let mut failures = Vec::new();
    for path in paths {
        let name = path.file_stem().unwrap().to_str().unwrap();
        let bytes = std::fs::read(&path).unwrap();
        let core = DocumentCore::from_bytes(&bytes).unwrap();
        let text = core.text_file_unicode_json();
        let pages = core.page_count();
        if let Ok(layer_page) = std::env::var("DOCNOTE_COMPAT_LAYER_PAGE") {
            let page: u32 = layer_page.parse().unwrap();
            if page < pages && name == "sample-04" {
                std::fs::write(
                    output.join(format!("{name}-layer-{page}.json")),
                    core.get_page_layer_tree_native(page).unwrap(),
                ).unwrap();
            }
        }
        let mut sample_pages = vec![0, 1.min(pages - 1), pages / 2, pages - 1];
        if let Ok(extra) = std::env::var("DOCNOTE_COMPAT_EXTRA_PAGE") {
            let page = extra.parse().expect("extra page is a zero-based index");
            if page < pages {
                sample_pages.push(page);
            }
        }
        sample_pages.sort();
        sample_pages.dedup();
        for page in &sample_pages {
            let svg = core.render_page_svg_native(*page as u32).unwrap();
            std::fs::write(output.join(format!("{name}-source-{page}.svg")), svg).unwrap();
        }
        for format in ["hwp", "hwpx"] {
            let saved = if format == "hwp" {
                core.export_hwp_native()
            } else {
                core.export_hwpx_native()
            }
            .unwrap();
            std::fs::write(output.join(format!("{name}-roundtrip.{format}")), &saved).unwrap();
            let reopened = DocumentCore::from_bytes(&saved).unwrap();
            let text_equal = reopened.text_file_unicode_json() == text;
            let page_equal = reopened.page_count() == pages;
            if !text_equal || !page_equal {
                failures.push(format!(
                    "{name}/{format}: text={text_equal}, pages={page_equal}"
                ));
            }
            for page in &sample_pages {
                if *page >= reopened.page_count() {
                    continue;
                }
                let svg = reopened.render_page_svg_native(*page as u32).unwrap();
                std::fs::write(output.join(format!("{name}-{format}-{page}.svg")), svg).unwrap();
            }
            results.push(
                json!({"sample": name, "format": format, "sourcePages": pages,
                "reopenedPages": reopened.page_count(), "textEqual": text_equal,
                "samplePagesZeroBased": sample_pages, "savedBytes": saved.len()}),
            );
        }
        assert_eq!(
            std::fs::read(path).unwrap(),
            bytes,
            "QA must never mutate its input"
        );
    }
    std::fs::write(
        output.join("results.json"),
        serde_json::to_vec_pretty(&results).unwrap(),
    )
    .unwrap();
    assert!(
        failures.is_empty(),
        "Compatibility differences: {failures:?}"
    );
}
