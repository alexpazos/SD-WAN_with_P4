#!/bin/bash
pandoc -f gfm -c bin/github-pandoc.css -t docx rdsv-p4.md -o rdsv-p4.docx
