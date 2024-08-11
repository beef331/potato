switch("path", "$projectDir/../src")
when appType == "lib":
  switch("nimMainPrefix", "lib")
--define:useMalloc
