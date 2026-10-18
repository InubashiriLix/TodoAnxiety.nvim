-- OpenCode-style tool contracts. The provider may eventually emit native tool
-- calls; this module owns the host-side schema rules either way.
local M = {}

M.min_options = 3
M.max_options = 5

M.ask_user = {
    name = "ask_user",
    description = "Ask the user 3-4 grounded questions about the current task. "
        .. "Each choice question has 3-5 concrete options; open-ended questions have none.",
    schema = {
        type = "object",
        required = { "questions" },
        properties = {
            questions = {
                type = "array",
                minItems = 1,
                maxItems = 4,
                items = {
                    type = "object",
                    required = { "id", "header", "question", "options" },
                    properties = {
                        id = { type = "string" },
                        header = { type = "string" },
                        question = { type = "string" },
                        multiple = { type = "boolean" },
                        intent = { type = "string" },
                        options = {
                            type = "array",
                            minItems = 0,
                            maxItems = M.max_options,
                            items = {
                                type = "object",
                                required = { "id", "label" },
                                properties = {
                                    id = { type = "string" },
                                    label = { type = "string" },
                                    description = { type = "string" },
                                },
                            },
                        },
                    },
                },
            },
        },
    },
}

M.finish = {
    name = "finish_plan",
    description = "Finish the current item or the final plan after the user's answers are sufficient.",
    schema = {
        type = "object",
        required = { "summary" },
        properties = {
            summary = { type = "string" },
            changes = { type = "array" },
        },
    },
}

function M.validate_option_count(count, multiple)
    assert(type(count) == "number" and count >= 0 and count % 1 == 0, "invalid option count")
    if count == 0 then
        return true
    end
    assert(
        count >= M.min_options and count <= M.max_options,
        (multiple and "multiple-choice" or "choice") .. " questions need " .. M.min_options .. "-" .. M.max_options .. " options"
    )
    return true
end

return M
