import QtQuick
import QtTest
import "../NoteFormat.js" as NoteFormat

TestCase {
  name: "NoteFormat"
  when: true
  function kinds(blocks) { return blocks.map(function (b) { return b.kind }).join(",") }

  function test_markdownSubset() {
    var b = NoteFormat.format("Goal: make it easy.\n\nKey sections:\n- Overview\n  - Nested item\n- **Install** steps\n1. First\n2) Second\n\n## Later\nWrapped\nparagraph", "#abc")
    compare(kinds(b), "paragraph,paragraph,bullet,bullet,bullet,numbered,numbered,heading,paragraph")
    compare(b[1].html, "Key sections:")
    compare(b[3].level, 1)
    compare(b[4].html, "<b>Install</b> steps")
    compare(b[5].marker, "1.")
    compare(b[6].marker, "2.")
    compare(b[8].html, "Wrapped paragraph")
  }
  function test_inlineStyles() {
    var html = NoteFormat.format("Use `qmllint` and *really* read [the docs](https://example.com) for _this_ one.", "#abc")[0].html
    compare(html, "Use <font color=\"#abc\">qmllint</font> and <i>really</i> read the docs for <i>this</i> one.")
    // snake_case and 2*3*4 are not emphasis.
    compare(NoteFormat.format("keep snake_case_name and 2*3*4", "#abc")[0].html, "keep snake_case_name and 2*3*4")
  }
  function test_noteTextNeverBecomesMarkup() {
    var html = NoteFormat.format("<img src=\"http://x/y.png\"> <a href=\"http://x\">hi</a> & **<b>**", "#abc")[0].html
    verify(html.indexOf("<img") < 0)
    verify(html.indexOf("<a ") < 0)
    compare(html, "&lt;img src=\"http://x/y.png\"&gt; &lt;a href=\"http://x\"&gt;hi&lt;/a&gt; &amp; <b>&lt;b&gt;</b>")
  }
  function test_oneLineSectionsAndInlineLists() {
    var b = NoteFormat.format("BUILD SPEC — spike for Edward. GOAL: test it. WHAT WE'RE TESTING: (1) does it help? (2) is it right? SUCCESS: hybrid wins. API: ok", "#abc")
    compare(kinds(b), "paragraph,paragraph,paragraph,numbered,numbered,paragraph")
    compare(b[0].html, "<b>BUILD SPEC</b> — spike for Edward.")
    compare(b[1].html, "<b>GOAL:</b> test it.")
    compare(b[2].html, "<b>WHAT WE'RE TESTING:</b>")
    compare(b[3].html, "does it help?")
    compare(b[4].marker, "2.")
    // Short all-caps words like "API:" stay inline.
    compare(b[5].html, "<b>SUCCESS:</b> hybrid wins. API: ok")
  }
  function test_plainAndEmpty() {
    compare(NoteFormat.format("", "#abc").length, 0)
    compare(NoteFormat.format(null, "#abc").length, 0)
    var b = NoteFormat.format("Just a short note.", "#abc")
    compare(kinds(b), "paragraph")
    compare(b[0].html, "Just a short note.")
  }
}
