let
  pkgs = import <nixpkgs> {};
in
with pkgs;
stdenv.mkDerivation {
  pname = "triav1c";
  version = "0.0.0-20200715-0";

  src = ./. ;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin
    cp src/static/triav1c.sh $out/bin/triav1c
    chmod +x $out/bin/triav1c

    wrapProgram $out/bin/triav1c \
      --prefix PATH : ${lib.makeBinPath [ ffmpeg libaom ]}
  '';
}