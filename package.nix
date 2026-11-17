{
  lib,
  fetchFromGitHub,
  trivialBuild,
}:

trivialBuild {
  pname = "visual-line-table-mode";
  version = "0.1.8";

  src = fetchFromGitHub {
    owner = "punzik";
    repo = "visual-line-table-mode";
    rev = "3cc264c6e8d9a054afa7280accc7828c59a675df";
    hash = "sha256-OhmzUgLq4csbB1Ymu4lxH5vM+jtL770FlODCC780ZWI=";
  };

  meta = {
    description = "Wrap prose without wrapping Org or Markdown tables";
    homepage = "https://github.com/punzik/visual-line-table-mode";
    license = lib.licenses.gpl3Only;
  };
}
