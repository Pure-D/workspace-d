function d
	if dub build $argv
		dub run :test
	end
end

function b
	dub build $argv
	mv workspace-d ~/etc-bin/workspace-d
	killall dcd-server; killall workspace-d
end

function r
	dub build --build=release $argv
end
