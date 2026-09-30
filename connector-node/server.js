const express = require("express");

const app = express();
app.use(express.json({limit:"8kb"}));

app.all("*",(req,res)=>{
  res.status(410).json({
    error:"Conector SQL Node retirado en C97.",
    action:"Usá CAPITAN_RODOLFO.bat. Capitán mantiene una sola conexión SQL y una sola base activa."
  });
});

app.listen(34721,"127.0.0.1",()=>{
  console.log("Conector Node retirado: iniciá ..\\CAPITAN_RODOLFO.bat para usar la conexión SQL única de Capitán.");
});
