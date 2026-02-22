#!/bin/bash
pandoc -f gfm -c github-pandoc.css -t pdf --pdf-engine=/Library/TeX/texbin/pdflatex sdedge-ns.md -o sdedge-ns.pdf
