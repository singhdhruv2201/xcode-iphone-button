-- Device details are passed at runtime by run.sh; no personal settings belong here.
on run arguments
	if (count of arguments) is not 2 then error "Use the installed run.sh so local device settings are supplied."
	set phoneName to item 1 of arguments
	set phoneIdentifier to item 2 of arguments
	if phoneName is "" or phoneIdentifier is "" then error "Device name and identifier are required."
	set phoneDestination to "platform=iOS,id=" & phoneIdentifier
	if application "Xcode" is not running then error "Open your project in Xcode on the Mac first."

	tell application "Xcode"
		set currentWorkspace to active workspace document
		if currentWorkspace is missing value then error "Select an open project window in Xcode first."
		if not (loaded of currentWorkspace) then error "Xcode is still loading the project. Try again shortly."
		set workspaceName to name of currentWorkspace
		if not (exists run destination phoneName of currentWorkspace) then
			error "The configured iPhone is not a run destination in this project. Check its name, pairing, and connection."
		end if

		-- Stop the old run so repeated taps do not leave a Replace dialog on the Mac.
		set previousAction to missing value
		try
			set previousAction to last scheme action result of currentWorkspace
		end try
		if previousAction is not missing value then
			if not (completed of previousAction) then
				stop currentWorkspace
				set stopDeadline to (current date) + 20
				repeat until completed of previousAction
					if (current date) is greater than stopDeadline then error "Xcode is still stopping the previous run. Try again shortly."
					delay 1
				end repeat
			end if
		end if

		-- Set this explicitly: a generic 'Any iOS Device' destination only builds.
		-- Avoid reading it back; some Xcode versions fail in the destination getter.
		set active run destination of currentWorkspace to run destination phoneName of currentWorkspace
		set actionResult to debug currentWorkspace run destination specifier phoneDestination skip building false
		set deadline to (current date) + 120
		repeat
			try
				set actionStatus to status of actionResult
			on error
				error "Xcode's action result is unavailable. Another run may have replaced this one; check Xcode."
			end try
			if actionStatus is succeeded then
				return "Xcode reports success: " & workspaceName & " on your iPhone."
			else if actionStatus is failed or actionStatus is error occurred or actionStatus is cancelled then
				set failureDetail to error message of actionResult
				if failureDetail is missing value or failureDetail is "" then
					set failureDetail to "Open Xcode's Report navigator for the build or launch error. Make sure the iPhone is unlocked and reachable."
				end if
				error "Xcode " & (actionStatus as text) & ": " & failureDetail
			end if
			-- A debug action can remain running until the app exits. Do not wait for that.
			if actionStatus is running then
				set actionBuildLog to build log of actionResult
				if actionBuildLog contains "Build succeeded" then
					return "Build succeeded for " & workspaceName & ". Xcode is launching/debugging it on the configured iPhone."
				end if
			end if
			if (current date) is greater than deadline then
				return "Xcode is still " & (actionStatus as text) & ". Installation is not yet confirmed; check Xcode for progress or a device prompt."
			end if
			delay 1
		end repeat
	end tell
end run
