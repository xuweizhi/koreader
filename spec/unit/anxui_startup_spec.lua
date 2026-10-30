describe("Anx startup policy", function()
    local policy, context
    setup(function() policy = dofile("plugins/anxui.koplugin/startup.lua") end)
    before_each(function()
        context = {first_owner = true, is_reader = false, guide_shown = true,
            original_start = "anxui", arguments = {"-d", "-v"}}
    end)
    it("opens only when Anx is the selected native startup target", function()
        assert.is_false(policy.shouldOpen({}, context))
        assert.is_true(policy.shouldOpen({startup = true}, context))
        for _, mode in ipairs({"filemanager", "last", "history", "favorites", "folder_shortcuts"}) do
            context.original_start = mode
            assert.is_false(policy.shouldOpen({startup = true}, context))
        end
    end)
    it("preserves explicit file, directory, URI and unknown launch arguments", function()
        for _, value in ipairs({"/books/book.epub", "/books", "file:///books/book.epub", "--", "--unknown"}) do
            context.arguments = {"-d", value}
            assert.is_false(policy.shouldOpen({startup = true}, context))
        end
    end)
    it("preserves onboarding, recovery and already active sessions", function()
        context.guide_shown = false
        assert.is_false(policy.shouldOpen({startup = true}, context))
        context.guide_shown = true; context.recovery = "unfinished_open"
        assert.is_false(policy.shouldOpen({startup = true}, context))
        context.recovery = nil; context.is_reader = true
        assert.is_false(policy.shouldOpen({startup = true}, context))
        context.is_reader = false; context.first_owner = false
        assert.is_false(policy.shouldOpen({startup = true}, context))
    end)
end)
