-- Independent Python 3 uuid.uuid5 known answers. Namespace: 01e2e885-f600-4118-80b6-f8470ece21bb
-- name = chr(31).join(["exposure", marker, subject, experiment, str(version), str(arm)])
-- expected = str(uuid.uuid5(uuid.UUID(namespace), name))
return {
	{ "marker", "spcid_ffffffffffffffffffffffffffffffff", "exp", 3, 0, "14ca539d-94e1-5502-9fca-05864c696330" },
	{ "marker", "spcid_ffffffffffffffffffffffffffffffff", "exp", 3, 1, "4a8daecf-9c97-56fd-bfca-434126415818" },
	{ "marker", "spcid_ffffffffffffffffffffffffffffffff", "exp", 3, 2, "90e1a5f3-0195-579f-899d-0415aeed1462" },
	{ "marker", "spcid_ffffffffffffffffffffffffffffffff", "exp", 3, 17, "d1b487bc-3c6e-51f2-a1ca-e7c7c6dec8e4" },
	{ "other", "spcid_ffffffffffffffffffffffffffffffff", "exp", 3, 0, "09b31192-81b3-5151-9f4d-19ac388d60b3" },
	{ "marker", "spcid_00000000000000000000000000000000", "exp", 3, 0, "cc61f106-f56c-51cc-a553-0f42d272eded" },
	{ "marker", "spcid_ffffffffffffffffffffffffffffffff", "other", 3, 0, "eb5155a0-2a1c-5113-a9a1-6895a6bc4a4e" },
	{ "marker", "spcid_ffffffffffffffffffffffffffffffff", "exp", 4, 0, "28fa1a47-61fb-5cec-b536-188136d12b1d" },
	{ "m", "s", "e", 1, 0, "719eb986-928f-5f27-a985-81d826458395" },
	{ "mmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmmm", "spcid_ffffffffffffffffffffffffffffffff", "experiment-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 2147483647, 1024, "f688a489-8b3d-5146-90a3-8346d21a456f" },
}
