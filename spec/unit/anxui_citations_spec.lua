describe("Anx answer citation rendering", function()
    local Markdown
    setup(function()
        require("commonrequire")
        Markdown = dofile("plugins/anxui.koplugin/ai/markdown.lua")
    end)

    it("links only known source IDs and keeps model links and code inert", function()
        local sources = {{id="S1",file="/a.epub"},{id="S2",file="/b.epub"}}
        local html = Markdown.document({sources=sources, content=[[
Known [S1], unknown [S9]. [website](https://example.invalid/)

`[S1]`

```
[S2]
```
<a href="file:///private">fake link</a>
]]}, function(text) return text end)
        local _, links = html:gsub('href="anx%-source:S1"', "")
        assert.are.equal(1, links)
        assert.is_nil(html:find('href="anx-source:S2"',1,true))
        assert.is_nil(html:find('href="anx-source:S9"',1,true))
        assert.is_nil(html:find("https://",1,true))
        assert.is_nil(html:find("file://",1,true))
        assert.is_truthy(html:find("[S9]",1,true), html)
        assert.are.equal(sources[1], Markdown.sourceForLink({uri="anx-source:S1"},sources))
        assert.is_nil(Markdown.sourceForLink({uri="https://example.invalid/S1"},sources))
        assert.is_nil(Markdown.sourceForLink({uri="anx-source:S1/extra"},sources))
        assert.is_nil(Markdown.sourceForLink({uri="anx-source:S9"},sources))
    end)

    it("keeps legacy answers without snapshots inert and links structured answers to their own sources", function()
        local translate = function(text) return text end
        assert.is_nil(Markdown.document({content="[S1]"},translate):find("href=",1,true))
        for _, mode in ipairs({"mindmap","parallel"}) do
            local html = Markdown.document({content="- Result [S1]",mode=mode,source_text="Original [S1]",
                sources={{id="S1",file="/original.epub"}}},translate)
            assert.is_truthy(html:find('href="anx-source:S1"',1,true))
        end
    end)

    it("links a citation next to Chinese punctuation", function()
        local html = Markdown.document({content="你好，这是流式回答。\n已收到问题：解释这一章，并引用 [S1]。",
            sources={{id="S1",file="/a.epub"}}},function(text) return text end)
        assert.is_truthy(html:find('href="anx-source:S1"',1,true),html)
    end)
end)
