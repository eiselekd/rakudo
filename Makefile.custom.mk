all:
	perl Configure.pl --prefix=/home/eiselekd/bin-moarvm --gen-moar --gen-nqp --backends=moar --moar-option='--debug' --force-rebuild --github-user=eiselekd
