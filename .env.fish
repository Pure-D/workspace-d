function b
	if dub build $argv
		dub run :test
	end
end

function r
	dub build --build=release $argv
end
