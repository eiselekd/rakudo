all:
	perl Configure.pl --prefix=/home/eiselekd/bin-moarvm --gen-moar --gen-nqp --backends=moar --moar-option='--debug' --force-rebuild --github-user=eiselekd
	make
	make install
	rm -rf zef
	git clone https://github.com/ugexe/zef.git
	cd zef; /home/eiselekd/bin-moarvm/bin/raku -I. bin/zef install .
