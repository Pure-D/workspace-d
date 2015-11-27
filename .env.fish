function b
	if dub build
		dub run :test
	end
end

function r
	dub build --build=release
end
