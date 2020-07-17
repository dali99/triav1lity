let
  pkgs = import <nixos-unstable> {};
in
with pkgs;
stdenv.mkDerivation {
  pname = "triav1c";
  version = "0.0.0-20200715-1";

  src = ./. ;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    mkdir -p $out/bin
    cp src/static/triav1c.sh $out/bin/triav1c
    chmod +x $out/bin/triav1c

    wrapProgram $out/bin/triav1c \
      --prefix PATH : ${lib.makeBinPath [ ffmpeg-full libaom bc ]} \
      --prefix MODEL_PATH : ${libvmaf}
  '';
}