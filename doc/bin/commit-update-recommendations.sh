date=$(date +"%d de %B de %Y (%H:%M)")
sed -i "s/^> Última actualización:.*/> Última actualización: $date/" ../rdsv-final.md
git add ../rdsv-final.md && git commit -m "Updating the recommendations document for the RDSV/SDNV 25-26 final project."