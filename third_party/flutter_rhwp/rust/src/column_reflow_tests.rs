use rhwp_core::{DocumentCore, parser::parse_hwp};

#[test]
fn column_reflow_updates_saved_line_breaks_and_restores_single_column() {
    let mut core = DocumentCore::new_empty();
    core.create_blank_document_native().unwrap();
    let text = "단 너비 변경 후에도 본문이 겹치지 않아야 합니다. ".repeat(25);
    core.insert_text_native(0, 0, 0, &text).unwrap();
    let original = parse_hwp(&core.export_hwp_native().unwrap()).unwrap();
    let single = &original.sections[0].paragraphs[0].line_segs;
    assert!(single.len() > 1);

    for count in [2, 3] {
        core.set_column_def_native(0, count, 1, true, 0).unwrap();
        let bytes = core.export_hwp_native().unwrap();
        let saved = parse_hwp(&bytes).unwrap();
        let paragraph = &saved.sections[0].paragraphs[0];
        assert_eq!(paragraph.text.trim_end_matches('\r'), text.trim_end_matches('\r'));
        assert!(paragraph.line_segs.len() > single.len());
        assert!(paragraph.line_segs[0].segment_width < single[0].segment_width);
        assert!(paragraph.line_segs.windows(2).all(|lines|
            lines[1].vertical_pos >= lines[0].vertical_pos + lines[0].line_height));
        let reopened = DocumentCore::from_bytes(&bytes).unwrap();
        assert_eq!(reopened.page_count(), core.page_count());
    }

    core.set_column_def_native(0, 1, 0, true, 0).unwrap();
    let restored = parse_hwp(&core.export_hwp_native().unwrap()).unwrap();
    let lines = &restored.sections[0].paragraphs[0].line_segs;
    assert_eq!(lines.len(), single.len());
    assert_eq!(lines[0].segment_width, single[0].segment_width);
}

#[test]
fn column_reflow_preserves_later_column_range_and_snapshot() {
    use rhwp_core::model::{control::Control, page::ColumnDef};
    let mut core = DocumentCore::new_empty();
    core.create_blank_document_native().unwrap();
    core.insert_text_native(0, 0, 0, &"범위별 줄 너비 보존 테스트 ".repeat(20)).unwrap();
    let mut document = core.document().clone();
    let mut later = document.sections[0].paragraphs[0].clone();
    later.controls.clear();
    later.controls.push(Control::ColumnDef(ColumnDef {
        column_count: 1, same_width: true, ..Default::default()
    }));
    let later_widths: Vec<_> = later.line_segs.iter().map(|l| (l.text_start, l.segment_width)).collect();
    document.sections[0].paragraphs.push(later);
    core.set_document(document);
    let before = core.export_hwp_native().unwrap();
    let snapshot = core.save_snapshot_native();
    core.set_column_def_native(0, 2, 1, true, 0).unwrap();
    let after = &core.document().sections[0].paragraphs[1];
    assert_eq!(later_widths, after.line_segs.iter().map(|l| (l.text_start, l.segment_width)).collect::<Vec<_>>());
    core.restore_snapshot_native(snapshot).unwrap();
    assert_eq!(core.export_hwp_native().unwrap(), before);
}

// Explicit local QA input only; no user document is mutated or bundled.
#[test]
#[ignore = "requires DOCNOTE_HWP_QA_INPUT pointing to a disposable local copy"]
fn column_reflow_qa_document() {
    let input = std::env::var("DOCNOTE_HWP_QA_INPUT").unwrap();
    let bytes = std::fs::read(input).unwrap();
    let mut core = DocumentCore::from_bytes(&bytes).unwrap();
    core.convert_to_editable_native().unwrap();
    let pages_before = core.page_count();
    let texts: Vec<_> = core.document().sections.iter().flat_map(|s| s.paragraphs.iter().map(|p| p.text.clone())).collect();
    for count in [2, 3, 1] {
        core.set_column_def_native(0, count, if count == 1 { 0 } else { 1 }, true, 0).unwrap();
        let saved = core.export_hwp_native().unwrap();
        let reopened = DocumentCore::from_bytes(&saved).unwrap();
        assert_eq!(reopened.page_count(), core.page_count());
        assert_eq!(texts, core.document().sections.iter().flat_map(|s| s.paragraphs.iter().map(|p| p.text.clone())).collect::<Vec<_>>());
        if count > 1 {
            assert_table_does_not_overlap_body(&core, 2);
            assert_table_does_not_overlap_body(&reopened, 2);
        }
        println!("columns={count}, original_pages={pages_before}, edited_pages={}, reopened_pages={}", core.page_count(), reopened.page_count());
    }
}

fn assert_table_does_not_overlap_body(core: &DocumentCore, table_para: usize) {
    use rhwp_core::renderer::render_tree::{RenderNode, RenderNodeType};
    fn nodes<'a>(node: &'a RenderNode, out: &mut Vec<&'a RenderNode>) {
        out.push(node);
        for child in &node.children { nodes(child, out); }
    }
    let tree = core.build_page_render_tree(0).unwrap();
    let mut all = Vec::new();
    nodes(&tree.root, &mut all);
    let table = all.iter().find(|n| matches!(&n.node_type, RenderNodeType::Table(t) if t.para_index == Some(table_para))).expect("cover table rendered");
    let mut body_runs = 0;
    for n in &all {
        if let RenderNodeType::TextRun(text) = &n.node_type {
            if text.cell_context.is_some() || text.para_index.is_none() { continue; }
            body_runs += 1;
            let x_overlap = (n.bbox.x + n.bbox.width).min(table.bbox.x + table.bbox.width) - n.bbox.x.max(table.bbox.x);
            let y_overlap = (n.bbox.y + n.bbox.height).min(table.bbox.y + table.bbox.height) - n.bbox.y.max(table.bbox.y);
            assert!(x_overlap <= 0.5 || y_overlap <= 0.5,
                "body {:?} at {:?} overlaps table {:?}", text.text, n.bbox, table.bbox);
        }
    }
    assert!(body_runs > 0, "body must still be rendered");
    fn check_column(node: &RenderNode, bottom: Option<f64>) {
        let bottom = if matches!(node.node_type, RenderNodeType::Column(_)) {
            Some(node.bbox.y + node.bbox.height)
        } else { bottom };
        if let RenderNodeType::TextRun(t) = &node.node_type {
            if t.cell_context.is_none() && t.para_index.is_some() {
                if let Some(bottom) = bottom {
                    assert!(node.bbox.y + node.bbox.height <= bottom + 0.5,
                        "body {:?} extends below column: {:?}, bottom={bottom}", t.text, node.bbox);
                }
            }
        }
        for child in &node.children { check_column(child, bottom); }
    }
    check_column(&tree.root, None);
}

#[test]
fn column_reflow_full_width_inline_table_reserves_neighbouring_columns() {
    use rhwp_core::model::{control::Control, table::{Table, Cell}, shape::{CommonObjAttr, TextWrap}};
    for count in [2, 3] {
        let mut core = DocumentCore::new_empty();
        core.create_blank_document_native().unwrap();
        let mut cover = core.document().sections[0].paragraphs[0].clone();
        core.insert_text_native(0, 0, 0, &"본문 줄은 표와 겹치지 않습니다. ".repeat(400)).unwrap();
        let mut document = core.document().clone();
        document.sections[0].paragraphs[0].controls.clear();
        document.sections[0].paragraphs[0].column_type = rhwp_core::model::paragraph::ColumnBreakType::None;
        document.sections[0].paragraphs[0].raw_break_type = 0;
        cover.controls.push(Control::Table(Box::new(Table {
            attr: 1, row_count: 1, col_count: 1, row_sizes: vec![1], cell_grid: vec![Some(0)],
            common: CommonObjAttr { width: 40000, height: 14000, treat_as_char: true,
                text_wrap: TextWrap::TopAndBottom, ..Default::default() },
            cells: vec![Cell { width: 40000, height: 14000, row_span: 1, col_span: 1,
                paragraphs: vec![Default::default()], ..Default::default() }],
            ..Default::default()
        })));
        document.sections[0].paragraphs.insert(0, cover);
        core.set_document(document);
        core.set_column_def_native(0, count, 1, true, 0).unwrap();
        assert_table_does_not_overlap_body(&core, 0);
    }
}
