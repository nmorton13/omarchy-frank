// Turns note text into display blocks for Text.StyledText. All note text is
// HTML-escaped first, so the only markup is the tags added here: notes can
// never inject links, images or other rich text.
.pragma library

function escape(text) {
    return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
// Inline Markdown: **bold**, *italic* / _italic_, `code`, [label](url) -> label.
function inline(text, codeColor) {
    var html = escape(text);
    html = html.replace(/\[([^\]]+)\]\([^)\s]+\)/g, "$1");
    html = html.replace(/`([^`]+)`/g, function (match, code) {
        return "<font color=\"" + codeColor + "\">" + code + "</font>";
    });
    html = html.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>");
    html = html.replace(/(^|[\s(])\*([^*\s][^*]*)\*(?=[\s).,;:!?]|$)/g, "$1<i>$2</i>");
    html = html.replace(/(^|[\s(])_([^_\s][^_]*)_(?=[\s).,;:!?]|$)/g, "$1<i>$2</i>");
    return html;
}
function block(kind, text, codeColor, marker, level) {
    return {
        kind: kind,
        html: inline(text, codeColor),
        marker: marker || "",
        level: level || 0
    };
}
// One-line notes often pack sections as "GOAL: … CORPUS: …" and inline lists as
// "(1) … (2) …". Break those into labelled paragraphs and numbered items.
var LABEL = /(^|\s)([A-Z][A-Z0-9'&\/-]*(?: [A-Z0-9'&\/-]+)*):\s/g;
function isLabel(label) {
    return label.replace(/[^A-Z]/g, "").length >= 4;
}
function splitSections(text) {
    var labels = [];
    var match;
    LABEL.lastIndex = 0;
    while ((match = LABEL.exec(text)) !== null) {
        if (isLabel(match[2]))
            labels.push({
                label: match[2],
                start: match.index + match[1].length,
                bodyStart: LABEL.lastIndex
            });
    }
    var sections = [];
    var preamble = text.slice(0, labels.length ? labels[0].start : text.length).trim();
    if (preamble)
        sections.push({
            label: "",
            body: preamble
        });
    labels.forEach(function (item, i) {
        sections.push({
            label: item.label,
            body: text.slice(item.bodyStart, i + 1 < labels.length ? labels[i + 1].start : text.length).trim()
        });
    });
    return sections;
}
function sectionBlocks(section, codeColor) {
    var blocks = [];
    var body = section.body;
    var items = null;
    if (/\(1\)\s/.test(body) && /\(2\)\s/.test(body)) {
        var parts = body.split(/\s*\((\d{1,2})\)\s+/);
        items = [];
        for (var i = 1; i + 1 < parts.length; i += 2)
            items.push({
                marker: parts[i] + ".",
                text: parts[i + 1].trim()
            });
        body = parts[0].trim();
    }
    var label = section.label ? "<b>" + escape(section.label) + ":</b>" : "";
    // A leading "TITLE — rest" reads as a label too.
    var dash = !label && /^([A-Z][A-Z0-9 '&\/-]{2,40}) — (.*)$/.exec(body);
    if (dash && isLabel(dash[1])) {
        label = "<b>" + escape(dash[1]) + "</b> —";
        body = dash[2];
    }
    if (label || body)
        blocks.push({
            kind: "paragraph",
            html: label + (label && body ? " " : "") + inline(body, codeColor),
            marker: "",
            level: 0
        });
    if (items)
        items.forEach(function (item) {
            blocks.push(block("numbered", item.text, codeColor, item.marker, 0));
        });
    return blocks;
}
function format(text, codeColor) {
    var source = String(text || "").replace(/\r\n?/g, "\n").trim();
    if (!source.length)
        return [];
    if (source.indexOf("\n") < 0) {
        var blocks = [];
        splitSections(source).forEach(function (section) {
            blocks = blocks.concat(sectionBlocks(section, codeColor));
        });
        return blocks;
    }
    // Multi-line notes: a small Markdown subset.
    var out = [];
    var paragraph = [];
    function flush() {
        if (paragraph.length)
            out.push(block("paragraph", paragraph.join(" "), codeColor));
        paragraph = [];
    }
    source.split("\n").forEach(function (line) {
        var heading = /^\s*#{1,6}\s+(.*)$/.exec(line);
        var bullet = /^(\s*)[-*•]\s+(.*)$/.exec(line);
        var numbered = /^(\s*)(\d{1,3})[.)]\s+(.*)$/.exec(line);
        if (!line.trim().length) {
            flush();
        } else if (heading) {
            flush();
            out.push(block("heading", heading[1], codeColor));
        } else if (bullet) {
            flush();
            out.push(block("bullet", bullet[2], codeColor, "•", Math.min(3, Math.floor(bullet[1].length / 2))));
        } else if (numbered) {
            flush();
            out.push(block("numbered", numbered[3], codeColor, numbered[2] + ".", Math.min(3, Math.floor(numbered[1].length / 2))));
        } else if (/:\s*$/.test(line.trim()) && !paragraph.length) {
            // A line like "Key sections:" introduces what follows.
            out.push(block("paragraph", line.trim(), codeColor));
        } else {
            paragraph.push(line.trim());
        }
    });
    flush();
    return out;
}
