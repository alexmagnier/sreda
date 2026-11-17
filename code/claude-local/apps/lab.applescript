-- «Лаборатория Claude»: opens the Claude Code chat in VS Code on the LOCAL model (bin/local-vscode lab).
-- Drop a folder or a file on the icon to open it there.
on run
	my launchIt("")
end run
on open theItems
	repeat with anItem in theItems
		my launchIt(POSIX path of anItem)
	end repeat
end open
on launchIt(p)
	set cmd to quoted form of (POSIX path of (path to home folder) & ".local/bin/local-vscode") & " lab"
	if p is not "" then set cmd to cmd & " " & quoted form of p
	try
		do shell script cmd & " 2>&1"
	on error errMsg
		display alert "Лаборатория Claude" message errMsg as critical
	end try
end launchIt
