-- Fixed local project and scheme; build only, without connecting to the iPhone.
on run arguments
    set projectPath to item 1 of arguments
    set schemeName to item 2 of arguments
    tell application "Xcode"
        open projectPath
        set workspaceRef to first workspace document whose path is projectPath
        if not loaded of workspaceRef then error "Project still loading"
        try
            set prior to last scheme action result of workspaceRef
            if prior is not missing value and not completed of prior then error "Project has an active action"
        on error messageText number errorNumber
            if messageText is "Project has an active action" then error messageText
        end try
        set active scheme of workspaceRef to scheme schemeName of workspaceRef
        set active run destination of workspaceRef to run destination "Any iOS Device (arm64)" of workspaceRef
        repeat with attempt from 1 to 2
            set actionResult to build workspaceRef
            set deadline to (current date) + 450
            repeat until completed of actionResult
                if (current date) > deadline then
                    stop workspaceRef
                    error "Build exceeded deadline"
                end if
                delay 1
            end repeat
            if status of actionResult is succeeded then return "succeeded"
            if status of actionResult is not cancelled then error "Build failed; inspect Xcode"
            delay 2
        end repeat
        error "Build cancelled"
    end tell
end run
