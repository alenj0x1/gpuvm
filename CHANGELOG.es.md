# Registro de cambios

Aquí se documentan los cambios importantes de GpuVM. El formato sigue [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y el proyecto usa [versionado semántico](https://semver.org/lang/es/).

[English](CHANGELOG.md)

Los cambios que esperan la próxima versión van en **Sin publicar**, arriba (esa sección solo existe mientras haya alguno y el sitio de documentación no la muestra); `scripts/release.py` la convierte en la versión nueva.

## [Sin publicar]

### Agregado
- **Los agentes de IA pueden usar tus máquinas.** GpuVM es un servidor MCP (`gpuvm.exe --mcp`): Claude Code, o cualquier cliente MCP, crea una máquina Windows desechable a partir de una plantilla de agente o toma una de las tuyas, y trabaja en ella con capturas, clics, teclas, arrastres, UI Automation, comandos y archivos mientras miras. Los agentes trabajan como un usuario estándar de Windows propio (`agent`), nunca como administrador; lo importante te lo piden en GpuVM, no en el chat: permisos de administrador, red, archivos que entran a la máquina, volver a un punto de restauración. Los avisos de UAC, la pantalla de bloqueo, las contraseñas y los pagos son siempre tuyos (`request_human`). Cada sesión de un agente queda grabada.
- **Mira a tu agente trabajar.** Sobre la imagen de la máquina se mueve el cursor del agente con su nombre, cada clic deja una onda, los arrastres dibujan su trazo y las teclas que presiona se ven un momento. La muesca de estado dice qué está haciendo con sus palabras («Claude Code · Dibujando la luna») o en simple («Ejecutando un comando», «Pensando…»), con **Tomar el control** al lado.
- **Toma el control cuando quieras.** Un clic, o una tecla con la imagen al frente, pausa al agente hasta que presionas **Volver al agente**; mover el mouse sobre la imagen nunca lo hace, así que puedes cruzarla para responder algo en otra ventana. Mientras el agente trabaja, nada de lo que hagas sobre la imagen llega a la máquina hasta que tomas el control. **Ajustes → Agentes** puede dejarlo solo para el botón.
- **Sección Agentes e historial.** Los agentes conectados con lo que hacen y sus últimos pasos, las solicitudes que te esperan, los archivos que entregan y el **Historial** de cada sesión: qué agente, en qué máquinas, cuándo, cuánto duró, cuántas acciones, comandos, aprobaciones y archivos, si tomaste el control, y su grabación. La página de cada máquina muestra los suyos.
- **Conecta Claude Code en un clic.** **Agentes → Conectar** agrega GpuVM a Claude Code y deja que sus herramientas corran sin que Claude Code pida permiso en cada paso; GpuVM sigue pidiendo lo importante, en su propio dock.
- **Entregas desde una máquina.** Un agente deja archivos en la **Bandeja de salida** de la máquina y te los ofrece; llegan a tu PC (Descargas\GpuVM) solo si los aceptas, copiados con tus propios permisos y marcados como descargados de internet.
- **Suelta archivos sobre una máquina y comparte el portapapeles.** Suelta archivos o carpetas sobre la imagen para copiarlos a la carpeta **Recibidos** de la máquina (1 GB en unos 25 segundos), envía lo seleccionado en el Explorador de una máquina a otra, y guarda las últimas 8 copias en el widget **Portapapeles** (solo en memoria; se saltan las copias privadas de los gestores de contraseñas).
- **Capturas, grabaciones y los últimos 30 segundos.** El widget **Captura** y Ctrl+Alt+Shift+P / R / B toman una captura, graban o guardan los últimos 30 segundos, sin recodificar y sin costo medible para la imagen. Los archivos van a Imágenes y Videos\GpuVM\<máquina>.
- **Puntos de restauración, máquinas desechables, exportar e importar.** Guarda un punto de restauración de una máquina y vuelve a él en un segundo (Hyper-V no admite puntos de control en máquinas con GPU, así que GpuVM usa los suyos); crea máquinas desechables desde una plantilla en un clic, que se borran al apagarse; exporta una máquina a un solo archivo `.gpuvm` e impórtala en otro PC. Las plantillas y exportaciones van compactadas.
- **Avisos de administrador en GpuVM.** El aviso de UAC de una máquina baja desde arriba de su imagen para responderlo ahí, en un tercio de segundo. Al salir de GpuVM con máquinas encendidas, un modo mínimo solo de avisos los sigue mostrando.
- **Un solo lugar para los avisos de estado.** Grabando, captura guardada, tomaste el control, un agente en pausa o trabajando: una muesca abajo de la imagen, o donde la pongas en **Ajustes → Apariencia**.
- **Los agentes pueden mirar mientras corre un comando.** `run` acepta `background: true`: responde al instante con un id, el agente sigue tomando capturas y actuando mientras el comando trabaja, y la herramienta nueva `run_result` da el código de salida y la salida. Dentro de la máquina, las capturas, la entrada, UI Automation y cada comando corren en paralelo, así que una captura nunca espera detrás de ninguno, y las acciones de entrada llegan siempre en el orden en que se enviaron.
- **`delayMs` en capturas y entrada.** `screenshot` espera ese tiempo antes de capturar; `click`, `type`, `key`, `scroll`, `drag` y `act` esperan después de actuar, antes de responder y antes de `screenshotAfter` (hasta 10 segundos). Los agentes ya no necesitan un `run` de `Start-Sleep` solo para esperar una ventana.
- **Los agentes pueden dibujar.** El `drag` de un agente también sigue un `path` de puntos, o varios `strokes` que se presionan y sueltan cada uno por su cuenta (un círculo, una espiral y una estrella en una sola llamada), con el `button` y la duración (`durationMs`) que elija. Se agregan movimientos intermedios para que apps como Paint reciban líneas suaves. Los agentes ya no tienen que escribir scripts de mouse dentro de la máquina para dibujar; si la persona toma el control, igual los detiene a mitad del trazo, con el botón suelto.
- **Informe de diagnóstico.** **Ajustes → Servicio → Guardar informe** guarda en Descargas un archivo de texto con los registros de la app y del servicio, para revisarlo y adjuntarlo al reportar un problema. Cada error que GpuVM muestra, o que le devuelve el servicio, queda ahora en el registro de la app con su hora.
- **winget en las máquinas de agentes.** Los agentes pueden instalar aplicaciones con `winget` como su propio usuario estándar (`--scope user`), sin Microsoft Store. GpuVM trae App Installer de la versión oficial de Microsoft, fijada por su SHA-256 y con la firma de Microsoft comprobada en este PC y otra vez dentro de la máquina, y lo instala para todos los usuarios. Una directiva bloquea los ajustes que debilitarían las comprobaciones de winget, y el origen de Microsoft Store queda apagado, así que un comando `winget` nunca se detiene en su aviso de condiciones. Las plantillas de agentes lo reciben en su próxima actualización; las demás máquinas de agentes, la próxima vez que se instale su agente.

### Cambiado
- **Sin límite en las sesiones de agentes por defecto.** Las sesiones se cortaban a los 500 pasos o 60 minutos, y se veía como «Paso 37 de 500»; ahora muestran lo que hicieron («212 acciones · 14 min») y **Ajustes → Agentes → Límite por sesión** pone un tiempo máximo para quien lo quiera.
- **El Sunshine propio de GpuVM en todas las máquinas.** Las máquinas transmiten con el fork de Sunshine de GpuVM ([gpuvm-sunshine](https://github.com/alenj0x1/gpuvm-sunshine)), siempre como servicio de Windows, sea cual sea su uso. Con la captura **Rápida** (la predeterminada), un ayudante pequeño captura como el usuario que inició sesión y le pasa los cuadros al servicio: hay imagen donde desktop duplication se quedaba en negro en la pantalla virtual, y ese usuario ya no puede leer la configuración ni las claves de Sunshine. Las máquinas creadas antes lo reciben la próxima vez que se abren, y se quita la configuración vieja que corría Sunshine como el usuario. Las máquinas de agentes y las demás funcionan igual, y las de agentes pueden elegir su captura como cualquier otra.
- **Las grabaciones del trabajo de los agentes ocupan de 10 a 35 veces menos.** El visor las recodifica mientras graba, en H.264 a 30 cuadros por segundo y calidad constante, en vez de guardar la transmisión de 180 fps: entre 0,3 y 1 GB por hora de trabajo de un agente en vez de casi 10 GB. El texto y los menús se ven nítidos, cualquier reproductor de Windows las abre y lo que ves en vivo no cambia; tus propias grabaciones conservan la transmisión completa. Requiere el visor actualizado.
- **Las plantillas se mantienen al día.** Cuando GpuVM trae un Sunshine o un agente más nuevo, sus plantillas lo reciben una vez, como una capa encima, en segundo plano (la app revisa al abrir y cada hora). Las copias de una plantilla de agentes quedan listas en menos de un minuto en vez de unos cinco; las máquinas ya creadas desde una plantilla conservan la suya sin cambios.

### Corregido
- Cuando un agente abre la imagen de una máquina, GpuVM y la imagen pasan al frente de tus otras ventanas (sin quitarte el teclado); antes, una imagen a pantalla completa podía abrirse detrás de la terminal mientras al agente se le decía que la veías.
- Los pedidos de un agente (como usar una de tus máquinas) salen como una notificación de Windows que se queda en pantalla hasta que la abras o la cierres, y se quita sola cuando lo respondes en GpuVM.
- El pedido del agente y la vista en vivo sobre la imagen ya no destellan en blanco o negro al aparecer.
- El número de pedidos pendientes junto a **Agentes** usa los dígitos normales de la app.
- Seguridad: el ayudante de captura de Sunshine solo habla con el ayudante que Sunshine inició; actualizar una plantilla ya no monta en tu PC el disco de la copia temporal (se limpia y se revisa desde dentro de la copia); el visor arranca con las mitigaciones de procesos de Windows (sin DLLs que él pueda escribir ni de red, sin extensiones inyectadas, ASLR forzado, manejadores estrictos).
- Actualizar GpuVM ya no deja instalado el servicio viejo cuando tardaba en detenerse.
- Abrir a mano una copia nueva de una plantilla de agentes ya no espera hasta 15 minutos en "Iniciando sesión en Windows".
- El `destroy` de un agente ya no informa un error cuando GpuVM ya había borrado la máquina.
- La imagen ya no se queda congelada cuando el servicio de captura de Windows falla dentro de la máquina: vuelve sola en unos 2 segundos, en vez de quedarse en el último cuadro hasta reabrir la máquina.
- Ya no aparecen franjas ni destellos negros sobre la imagen de una máquina (con juegos, videos, apps abriéndose, lo que sea). Windows a veces entregaba a la captura de GpuVM un cuadro del escritorio de la máquina que todavía estaba dibujando, y lo que faltaba dibujar salía negro durante un cuadro: una franja, una cuña con bordes escalonados o toda la pantalla. Ahora la captura revisa cada cuadro y, si no está terminado, lo vuelve a tomar cuando Windows lo termina, casi siempre en menos de un milisegundo. Las máquinas lo reciben la próxima vez que se abren. Las capturas de pantalla de los agentes hacen lo mismo (agente 0.4.10), así que un agente ya no recibe capturas con franjas negras.
- Las grabaciones se abren con el reproductor de Windows en PCs sin la extensión HEVC de Microsoft: con el códec en automático, esos PCs transmiten en H.264.
- La captura que toma un agente justo después de una acción muestra esa acción. Antes, una captura justo después de un `drag` (o de un clic que abre algo) solía volver sin ella, y los agentes tomaban una segunda captura para verla. Las capturas tardan unos 30 ms más (un `settleMs` que el agente puede cambiar). Requiere el agente 0.4.9.
- La muesca de estado, el cursor del agente, sus solicitudes y el panel lateral aparecen en todas las máquinas, no solo en la primera tras abrir GpuVM: una ventana ocultada por GpuVM quedaba oculta para siempre. También vuelven los avisos de la muesca (captura, grabación, últimos 30 segundos), y Ctrl+Alt+Shift+G abre el panel lateral cada vez.
- Ya no aparece una barra «GpuVM» arriba a la derecha al cerrar el panel lateral, la imagen o la muesca, ni un fondo claro detrás de las esquinas redondeadas de la muesca: las ventanas de GpuVM sobre la imagen ya no tienen una superficie que Windows pueda pintar.
- La muesca y la solicitud de arriba de la imagen se quedan donde están al abrir el panel lateral; solo se corre la que el panel taparía.
- Mientras un agente trabaja, y mientras tienes el control, el puntero se mueve libre sobre la imagen, así que **Tomar el control** y **Volver al agente** de la muesca responden al clic sin pulsar antes Ctrl+Alt+Shift+Z. Requiere el visor actualizado.
- Un solo clic en la imagen toma el control mientras trabaja un agente (hacían falta dos), y el cursor propio de la máquina ya no se ve detrás del cursor del agente.
- Los avisos emergentes de Windows (un dispositivo que se configura, las ofertas de OneDrive) ya no aparecen en las máquinas de agentes, donde se quedaban con el foco y las teclas del agente iban a ellos (agente 0.4.13).
- La imagen dentro de la ventana se queda delante de GpuVM cuando GpuVM recibe el foco (podía quedar detrás y dejar la ventana en negro), y la muesca, la solicitud y el cursor del agente quedan sobre la imagen cuando esta pasa al frente.
- Los programas que un agente abre con `run` pasan al frente, como cuando los abre una persona, en vez de quedar detrás de la ventana activa (agente 0.4.12).
- `ui_invoke` funciona con los ids que lista `ui_tree` (salían como «?» y todo invoke fallaba), y `ui_tree` también lista un menú contextual o ventana emergente abierta (agente 0.4.12).
- «Permitir en esta tarea» deja pasar las siguientes solicitudes del mismo tipo en la misma máquina sin volver a preguntar.
- La notificación de Windows de una solicitud desaparece cuando la solicitud vence, y las que quedaron de una ejecución anterior se borran al abrir GpuVM.
- Las sugerencias de «Información guardada» del navegador ya no tapan los botones de los diálogos, un aviso nunca tapa los botones de un diálogo abierto, y el diálogo de espacios ya no se dibuja debajo de la barra lateral.
- Las actualizaciones de plantillas se reintentan una hora después si al PC le falta memoria, en vez de fallar.
- El servicio de GpuVM ya no deja de responder a todo (hasta reiniciarlo) cuando la lista de agentes de la app y la lista de máquinas de un agente se leían en el mismo instante.
- Cambiar el nombre de una máquina con puntos de restauración funciona siempre: la segunda vez fallaba («Failed to modify device 'Virtual Hard Disk'») porque su disco se conectaba en la carpeta nueva antes de que llegaran sus puntos de restauración.
- Una tecla pulsada justo después de **Volver al agente** vuelve a tomar el control cuando el agente sigue trabajando, en vez de perderse; y los botones de la muesca quedan siempre sobre la imagen, así que un clic en ellos nunca cae en la máquina.

## [0.9.0] - 2026-11-18

### Agregado
- **Visor propio de GpuVM.** Las máquinas se abren dentro de la app, en el visor de GpuVM (basado en Moonlight): el cubo de la máquina pasa al centro con los pasos mientras se conecta y luego la imagen llena la ventana bajo la barra de título. **Inicio** (en la barra de título, el panel lateral o Ctrl+Alt+Shift+H) se aleja hasta Inicio y deja la máquina conectada, así que al abrirla otra vez vuelve al instante a su imagen; **Ajustes → Ventana** puede desconectarla en su lugar. Una máquina configurada a pantalla completa pasa a pantalla completa cuando su imagen está lista, y la pantalla completa se cambia desde el panel. Cambiar de máquina se aleja de una y trae la otra al centro, y las esperas muestran consejos.
- **Panel lateral junto a la imagen.** Ctrl+Alt+Shift+G abre un panel que corre la imagen a un lado. Es un tablero de widgets que acomodas: máquinas con sus cubos, acciones (Inicio, pantalla completa, estadísticas sobre la imagen, desconectar), los números de la imagen con su historial, un reloj, un estante con las figuras de cada máquina, los juegos y el clima. **Editar** agrega, quita, mueve y cambia el tamaño de los widgets, y la distribución se recuerda; cada widget muestra más a medida que crece. Su borde se arrastra para ensancharlo. El clima queda apagado hasta escribir una ciudad, y a Open-Meteo solo va el nombre de la ciudad.
- **Fluidez y calidad de las animaciones.** **Ajustes → Apariencia** limita los cuadros por segundo de los hologramas y escenas (15, 30, 60, 120 o todos los que muestre el monitor) y la resolución con que se dibujan (25 a 100 %), para dejar más GPU a las máquinas. Por defecto nada cambia.

### Cambiado
- **La app le devuelve la GPU a las máquinas.** Los hologramas y escenas se detienen mientras se ve la imagen de una máquina, dentro de la app o a pantalla completa, y dibujan a 30 cuadros por segundo mientras GpuVM no tiene el foco. La pantalla del cubo y sus líneas de escaneo cuestan menos de dibujar.
- **Menos latencia en la transmisión.** Las máquinas con NVIDIA codifican en una sola pasada, cerca de 1 ms menos por cuadro (latencia de entrada de unos 13,4 a 11,4 ms en promedio). Las máquinas ya creadas lo reciben la próxima vez que se abren.
- **Inicio carga** como los cubos de las propias máquinas unidos por líneas por donde viaja la luz, en lugar de un anillo.

### Corregido
- Cambiar la pantalla virtual o la salida de audio de una máquina que captura con Windows Graphics Capture ya no deja detenido su servidor de transmisión, lo que hacía fallar la siguiente apertura.
- Abrir una máquina cuyo visor se cerró mientras tanto la abre de nuevo en lugar de mostrar una pantalla oscura.
- La tarjeta de Ajustes ya no parpadea al cambiar de sección, y las tarjetas de Inicio ya no se cortan entre 1100 y 1300 px de ancho.

### Seguridad
- **El visor corre aislado.** Lee lo que envía el servidor de transmisión de la máquina, así que corre con integridad baja y un token restringido (sin derechos de administrador aunque GpuVM corra elevada) dentro de un job: un solo proceso, que termina con la app, sin cambiar de escritorio, cerrar sesión, cambiar parámetros del sistema ni modos de pantalla, ni escribir en el portapapeles. No puede escribir tus archivos ni el registro, abrir el proceso de GpuVM ni enviar mensajes a sus ventanas. La app le habla por una tubería privada que solo tu usuario puede abrir, con un token de un solo uso, y lo sigue por el identificador de su proceso.
- La ventana del visor se usa solo si pertenece a su propio proceso, se trae al frente solo justo después de que la app pidió la imagen, y se abre una máquina a la vez.
- Cada ventana de la app solo puede llamar a sus propios comandos: el panel lateral no puede tocar el servicio ni reabrir GpuVM como administrador.

## [0.8.0] - 2026-11-16

### Agregado
- **Inglés.** GpuVM habla inglés además de español. **Ajustes → Apariencia → Idioma** sigue al de Windows (español si Windows está en español, inglés si no) o queda fijo; todas las pantallas, el menú de la bandeja y lo que informa el módulo (pasos, avisos y errores) cambian a la vez.
- **Reordenar arrastrando.** Arrastra una máquina en la barra lateral a otro lugar, en su espacio o en otro: las demás le hacen lugar mientras pasa y se ve atenuada donde caería. Los espacios se reordenan igual, arrastrando su nombre.
- **Logo nuevo.** Un chip de GPU dividido en cuatro con una parte en color: la parte de la GPU que recibe cada máquina. Es el ícono de la app, del instalador y el de la barra lateral.
- **Color de énfasis.** En **Ajustes** se elige el color (azul, violeta, turquesa, verde o ámbar), cada muestra mitad clara y mitad oscura; el cambio de tema claro u oscuro también está ahí.
- **Elegir el usuario de Windows** al crear una máquina (antes siempre era `gpuvm`), con aviso al escribir si Windows reserva ese nombre.
- **Nueva plantilla desde la Biblioteca.** Se elige la máquina de la que se guarda Windows y su nombre, igual que desde el menú de la máquina.
- **Personalizar una máquina.** Una sección nueva, **Personalizar**, decora su cubo: un color propio para el holograma, los rayos y su ícono (el de énfasis si no se elige); un letrero LED cuyo texto corre alrededor del vidrio, en ámbar, rojo, verde, blanco o el color de la máquina, y si se quiere con el uso de su GPU y su procesador; stickers para el vidrio (GpuVM, estrella, rayo, corazón, gato, perro, araña, fantasma, cohete, fuego, diamante, luna, control o una imagen propia); y figuras de bloques que se paran encima, dibujadas en la GPU (gato de la suerte, planta, patito, robot, cactus, hongos, control, taza, pingüino, cohete, bonsái, perro, gato, araña, cubo mágico, conejo, oso, unicornio, tigre, cervatillo). **Decorar al azar** lo llena todo en un clic, también al crear una máquina, que tiene su propia sección Personalizar. Al arrastrar se ven las celdas de la cara iluminadas con el color de énfasis y lo movido encaja en ellas; el letrero LED también se sube y se baja arrastrándolo. Se arrastran al cubo y sobre él, y se giran manteniendo el clic derecho y arrastrando de lado (encajan cada 15°), y con un clic derecho cambian de tamaño, se duplican o se quitan, o se eligen y quitan desde la lista de lo que tiene la máquina. Se pueden elegir varios a la vez (Shift o Ctrl y clic, un recuadro con Shift en un espacio vacío, o Ctrl+A) y se mueven, giran, duplican (Ctrl+D) o quitan juntos; las flechas los mueven de a una celda. Lo elegido se ve con una capa tenue del color de énfasis. Cada máquina conserva su decoración, también al cambiarle el nombre, y se ve en Inicio. Sin máquinas todavía, Inicio muestra máquinas decoradas al azar, una nueva cada pocos segundos.
- **Juegos en el espacio de máquinas.** **Jugar**, sobre el espacio de Inicio, abre una galería de juegos, cada uno en una tarjeta donde el propio juego se juega solo, con su récord. Antes de jugar, una pantalla muestra el juego corriendo con la máquina y el modo que elijas (en equipo, tus otras máquinas vuelan a su lado; al cambiar de máquina o de modo, las que salen se van volando y entran las nuevas), los controles dibujados como teclas y botones del mouse, algunos consejos y tu récord. *Overclock*: tu máquina vuela entre bloques y máquinas rivales, se mueve con el teclado y apunta con el mouse a cualquier parte; los stickers traen armas (más rápida, triple, ráfagas, en todas direcciones), un escudo o una vida; derribar llena un frenesí en el que todo se acelera y tus figuras salen gigantes y atraviesan todo. Disparar y derribar cargan una habilidad que se usa con el clic derecho (o E): al principio un pulso, y los núcleos que pasan la cambian por un láser, tiempo lento, clones o un imán. Empieza en el mundo del espacio donde se juega y cada 40 segundos cruza a otra zona (el estudio, una placa base, un mundo de bloques), y lo que viene hacia ti está hecho de esa zona: placas de holograma, chips, condensadores y resistencias, o bloques y figuras de bloques. Eliges la máquina con la que juegas (vuela con su color y su figura encima) y un modo: **Solo**, o **En equipo**, donde tus otras máquinas vuelan contigo y disparan solas contra más rivales y más duros. *Bit a bit*: tu máquina salta entre los huecos de las columnas, en el estudio (pilares de holograma), sobre una placa base o entre bloques, con bits que valen doble. Cada juego y modo guarda su récord. *Stack*: un bloque se desliza sobre la torre y un clic lo suelta; lo que sobresale se cae y la torre se angosta, soltarlo justo encima es un Perfecto que vale doble y tres seguidos hacen crecer el bloque. Tu máquina es la base y su figura va en la cima; cada 8 pisos la torre sube a otro mundo (bloques, una placa base, el estudio y luego el espacio) y se pone más difícil. *Cache*: llueven figuras de bloques y tu máquina las atrapa a lo largo del suelo con el mouse (o A/D); cada una que llega al suelo cuesta un corazón. Las doradas valen cinco, las arañas cuestan un corazón si las atrapas y los stickers traen un clon que atrapa a tu lado, más ancho, tiempo lento, imán, escudo o un corazón.
- **Cubo más ancho.** En la página de una máquina, arrastrando el borde del panel del cubo se ensancha (nunca aprieta las opciones y se recuerda).
- **Cambiar el nombre de una máquina.** **Cambiar nombre** en el menú de la máquina (apagada) revisa el nombre nuevo mientras se escribe, y el cubo de al lado lo graba en la etiqueta de serie de la placa. La máquina cambia de nombre en Hyper-V junto con su carpeta y su disco; conserva su configuración, el emparejamiento con Moonlight, los discos compartidos, la última apertura y el diseño de banner elegido. Si un paso falla, se deshace lo que ya se había renombrado. El módulo suma `Rename-GpuVM` (`./gpuvm.ps1 rename`).
- **Espacios.** Agrupa las máquinas según para qué son (trabajo, juegos, pruebas con IA…). Inicio muestra un espacio a la vez, elegido en pestañas sobre el escenario que se desplazan con la rueda, solo con sus máquinas; la barra lateral las lista bajo su espacio; una máquina nueva va al espacio desde donde se crea; en **Personalizar** de una máquina se cambia de espacio o se crea uno nuevo. Las máquinas también se arrastran desde la barra lateral o desde las tarjetas de Inicio a otro espacio y se deslizan a su lugar nuevo. Un espacio sin máquinas ofrece una tarjeta **Nueva máquina** y las máquinas de otros espacios para traer.
- **Mundos para los espacios.** Cada espacio tiene su mundo: **Placa base** (chips, condensadores, conectores, pistas con datos que corren en el color de énfasis y los nombres del espacio y de la máquina impresos junto a su zócalo) o **Bloques** (una placa de studs con caminos, un estanque, árboles, casas y las figuras de bloques, de día, de tarde, de noche o según la hora), o el **Estudio** de siempre. El mundo gira y se acerca con el cubo, cubre toda la vista, tiene una luz que sombrea cada pieza y proyecta sombras (también las de las máquinas) y el holograma ilumina el suelo bajo cada máquina. Entre bloques, la máquina también está hecha de bloques, sus rayos son cadenas de bloquecitos y su pantalla un mosaico con un paisaje del mismo momento del día.
- **Vistas fijas al personalizar.** Un panel sobre el cubo lo muestra de frente, de cada lado, por detrás o desde arriba y lo deja quieto ahí.
- **Copiar, cortar y pegar la decoración.** Ctrl+C, Ctrl+X y Ctrl+V (también en el menú del clic derecho) copian stickers y figuras, también de una máquina a otra.
- **Detalles.** Al cambiar de máquina, su página abre en la misma sección y en el mismo lugar; la fila de máquinas de Inicio se mueve arrastrándola; arrastrar con la rueda presionada mueve el cubo; el texto seleccionado toma el color de énfasis; al contraer la barra lateral, los nombres de los espacios cierran su lugar y las máquinas suben juntas.

### Cambiado
- **Interfaz nueva.**
  - Tema oscuro en grises grafito neutros, sin tinte azul; la barra lateral y la barra de título son una sola superficie y el contenido va encima con una esquina redondeada. Inicio, Biblioteca y Ajustes están en la barra lateral; arrastrando su borde se cambia el ancho y con un clic en la línea del borde (o arrastrándola hasta angostarla) se contrae.
  - El ícono de cada máquina muestra las cuatro celdas del logo con su parte en su color. Su banner es una escena de chips que se mueve con la GPU, parpadea con el procesador y se llena con la memoria; **Otro banner** en su menú cambia entre tres.
  - Junto a las opciones de una máquina, siempre a la vista, está la máquina en holograma dentro de un cubo de vidrio: placa madre, procesador (una celda por hilo), memoria (un módulo por cada 4 GB), tarjeta gráfica (su parte de la GPU como una tira de luces) y disco, las apps flotando alrededor y su pantalla proyectada arriba. Los rayos llegan a cada pieza tanto como trabaja; lo que la limpieza deja fuera rebota en el vidrio. Se gira arrastrando, se acerca con la rueda y vuelve con doble clic. Sigue lo que se cambia antes de guardar: la cámara se acerca a la pieza que cambia y luego vuelve, y un perfil que cambia varias a la vez las recorre mientras el holograma se rearma. Al crear una máquina se ve el mismo cubo, armado según lo que se elige.
  - El cubo comparte su espacio con tus otras máquinas, dibujadas pequeñas debajo; si se deja un rato, la máquina flota y luego se une a ellas como una constelación, y al volver a usarla regresa al frente. Abrir otra máquina sigue en el mismo espacio: la que estabas viendo vuelve con las demás y la nueva pasa al frente. Cada app tiene su lugar dentro del cubo, sean las que sean.
  - La placa lleva una etiqueta de serie con el nombre de la máquina; al escribirlo al crear una máquina, la cámara va hacia ella mientras se graba letra por letra.
  - El encabezado de la máquina y su franja de uso son un solo panel; su Windows, su GPU y su perfil (con su nombre, Equilibrado) van como piezas pequeñas con ícono.
  - Cambiar de máquina es rápido, como un corte: la cámara gira de golpe mientras cambian de lugar.
  - La parte de color del logo sigue el color de énfasis.
  - La página de una máquina es una sola, con una barra que marca la sección a la vista (máquina, imagen y control, Windows). Procesador, memoria, GPU y tiempo encendida van en una franja con sus últimos cinco minutos en pequeñas gráficas.
  - Las opciones son filas con ícono y una línea que las explica. Los controles deslizantes muestran su escala y lo que le queda al PC; las listas y el monitor usan la lista desplegable propia de la app.
  - Los cuadros por segundo se ofrecen según el monitor donde se abre la máquina (su ritmo, los que van parejos con él y los que pueden dar tirones) y un valor personalizado.
  - **Tipo de uso** encabeza su grupo y fija debajo los cuadros por segundo, la sincronización vertical, el ritmo de cuadros y el mouse; cambiar uno a mano lo pasa a **Personalizado**.
  - La limpieza de Windows lista todo lo que Windows trae (rastreo, publicidad, Bing, Copilot, apps preinstaladas, OneDrive, widgets, servicios de fondo) cada cosa dice qué hace ahora o, si el nivel elegido la quita, cómo queda Windows sin ella, junto a una escena donde esas piezas dejan de llegar a Windows.
  - Apps: el catálogo por categoría en mosaico o lista a la izquierda, con las instaladas marcadas; el buscador y las apps de esta máquina a la derecha.
  - Los discos compartidos dicen para qué sirven.
  - Inicio abre en el espacio de las máquinas: la que está en uso (o la última abierta) en su cubo con las demás al lado, y junto a ella el uso de procesador, memoria y GPU, la memoria libre y sus acciones. Debajo, las demás máquinas con su acción, la Biblioteca de un vistazo con **Crear máquina** y lo pendiente.
  - La Biblioteca es una sola página con todas sus secciones. Arriba, en qué se va el espacio de GpuVM en el disco (discos de máquinas, plantillas, discos compartidos e ISOs, cada uno con su color) y cuánto queda libre. Los perfiles son tarjetas con un cubito de lo que dan, la cuadrícula crece con los que haya y su última tarjeta crea uno nuevo. Plantillas, discos compartidos, discos de máquinas e ISOs son tarjetas igual, cada una con un dibujo de lo que es (el Windows de una plantilla, un disco lleno hasta donde se usa, un disco de instalación). Al editar un perfil, la máquina que arma se ve al lado del formulario.
  - Ajustes: las secciones a la izquierda (Apariencia, Ventana, Máquinas, Servicio) cambian lo que se muestra al centro, con una vista previa en vivo del tema y el color de énfasis a la derecha.
  - Los avisos (un driver que actualizar, apps que faltan) van sobre la superficie de las tarjetas; solo su ícono lleva el color de advertencia.
  - Inicio cabe en la ventana sin desplazarse, y la Biblioteca abre arriba. En Inicio, las líneas entre sus partes se arrastran para cambiar su tamaño (el espacio de las máquinas y la fila de abajo, el panel del espacio, las máquinas, la Biblioteca y lo pendiente; doble clic vuelve al tamaño normal); la fila de máquinas se desplaza de lado cuando son muchas. Las tarjetas se deslizan a su nuevo lugar al cambiar el tamaño de la ventana o al aparecer o irse una.
  - En la barra lateral, una máquina encendida muestra una pequeña gráfica de su último minuto: procesador, memoria y GPU con sus colores.
  - Con muchas máquinas todo sigue fluido: las escenas fuera de la vista no se dibujan e Inicio solo vuelve a dibujar las tarjetas que cambiaron.
  - Sin máquinas, Inicio muestra una máquina vacía en el cubo con lo que la Biblioteca ya tiene listo y **Crear máquina**; una Biblioteca vacía muestra en cada sección la tarjeta para agregar el primero.
  - Crear una máquina es un diálogo grande: secciones a la izquierda y un resumen siempre a la vista a la derecha. Un perfil llena todo, y lo que se cambie se puede guardar como perfil nuevo.
- **El tamaño de los discos cuenta el espacio prometido a las demás máquinas.** Un disco dinámico crece hasta su tamaño a medida que la máquina escribe, así que el espacio libre de la unidad no era el límite real: se podía dar a varias máquinas más de lo que cabe. Crear una máquina, el control **Disco** de un perfil y **Opciones → Disco** ahora llegan hasta lo que cabe con todos los discos de esa unidad llenos, dejando 20 GB para Windows. **Opciones** muestra una barra con el disco de esta máquina, lo reservado para las demás y lo que quedaría libre. `Get-GpuVMHostInfo` lo devuelve como `disk` y `Get-GpuVMOverview` como `options.diskBudget`.
- **El mundo de bloques sigue fluido con la cámara baja.** Las tachuelas de la base se dibujan en la GPU de una vez (miles cerca del suelo), así que girar la cámara a ras del piso ya no da tirones.
- **El borde del cubo llega hasta el final.** En la página de una máquina, la línea entre las opciones y el cubo va de borde a borde: a la derecha el cubo se pliega en una franja y a la izquierda ocupa todo el ancho; doble clic la devuelve a su lugar. Con la columna de opciones angosta, cada control va debajo de su texto.
- **Las pestañas de sección se deslizan** hasta su sección en la Biblioteca y en la página de una máquina, y la dejan justo bajo la barra.
- **Un modo claro más limpio.** El texto secundario se lee mejor sobre blanco, los banners se notan más, el hover y la selección en listas son un blanco apenas gris, las opciones van sin líneas entre ellas, lo que va debajo de una opción usa todo el ancho de la tarjeta, los íconos de máquina son tonos de su propio color, los mosaicos y los stickers van sin borde gris y las esquinas del cubo son cuadradas.

### Corregido
- **Los menús abiertos dentro de un diálogo se ven encima de él.**
- **El nombre vuelve a grabarse en la placa** mientras lo escribes al crear una máquina, y el diálogo de cambiar nombre queda al lado del cubo en vez de debajo.

## [0.7.0] - 2026-11-09

### Añadido
- **Elige el monitor donde se abre una máquina.** **Preferencias → Abrir las máquinas en** lo fija para todas (**Principal**, el predeterminado, sigue al monitor principal de Windows) y **Opciones → Abrir en** de cada máquina puede cambiarlo. Moonlight no tiene un ajuste para esto, así que GpuVM mantiene sus ventanas en ese monitor mientras se abre; la elección se guarda y, si el monitor no está conectado, se abre en el principal. Con los FPS en **Monitor**, el stream usa la frecuencia de ese monitor. El módulo suma `Get-GpuVMMonitor`, `Connect-GpuVM -Monitor` y `Set-GpuVMStreamingClient -Monitor`.
- **Apps ya instaladas.** La tarjeta **Apps** las muestra con una marca en lugar de la casilla, así que no se pueden elegir otra vez. Con un clic, o clic derecho, ofrecen **Reinstalar** y **Desinstalar**, que usa el desinstalador de la propia app tras pedir confirmación. El módulo suma `Get-GpuVMInstalledApp`, `Uninstall-GpuVMApp` e `Install-GpuVMApp -Reinstall`; las plantillas y sus copias conservan la lista.

### Corregido
- **Abrir una máquina apagada espera a que Windows inicie sesión.** La pantalla, la captura de Sunshine y el sonido se preparan cuando Windows ya inició sesión, con **Iniciando sesión en Windows** en el botón mientras tanto; antes fallaban con avisos y dejaban la imagen en otra resolución. GpuVM también dice cuándo Windows está terminando actualizaciones o se reinicia para terminarlas.
- **Apagar avisa cuando Windows instala actualizaciones.** Puede tardar minutos, y el siguiente encendido dice que Windows las está terminando; salir de GpuVM con **Apagarlas** también lo recuerda. El botón principal de la máquina es más ancho para que quepan sus pasos.

## [0.6.0] - 2026-11-09

### Añadido
- **Biblioteca → Discos** muestra cada **Windows preparado** con el espacio que ocupa, y se puede borrar tras confirmar en UAC. El módulo suma `Get-GpuVMBase` y `Remove-GpuVMBase`.

### Cambiado
- Crear una máquina tarda cerca de 1 minuto en vez de casi 3, y el equipo ya no se pone lento mientras tanto. Windows se aplica una vez por ISO y edición (unos 12,5 GB, guardados en la carpeta de las VMs) y cada máquina nueva lo copia; la primera máquina con un ISO nuevo tarda unos 6 minutos, también sin frenar el equipo.
- Aplicar Windows corre con prioridad baja, y la copia regula sus propias escrituras para que los guardados de los demás programas no se traben mientras corre.
- Los discos se montan sin letra de unidad mientras se crea una máquina, así no aparece ninguna unidad en el Explorador de archivos.
- La lista de archivos del driver de la GPU se recuerda por versión del driver, así crear una máquina o actualizar su driver se ahorra unos 30 s de búsqueda.
- `max-performance` usa disco dinámico: uno fijo no era más rápido dentro de la VM y escribir sus 96 GB al crearla tardaba minutos. **Fijo** sigue disponible en los perfiles personalizados.

## [0.5.0] - 2026-11-08

### Añadido
- Los mandos funcionan en las máquinas: GpuVM instala el controlador de mando virtual (ViGEmBus) en la VM, y un control conectado a este equipo llega a Windows en la VM como un control de Xbox 360.
- Cada máquina tiene un **Tipo de uso** que ajusta Moonlight para lo que haces en ella. **Juegos**, **Películas y video** o **Trabajo** ajustan los FPS, la sincronización vertical, el ritmo de cuadros y el mouse de Moonlight para ese uso; si cambias alguno a mano, aparece **Personalizado**. Los perfiles de la Biblioteca también lo guardan.
- Sincronización vertical, ritmo de cuadros y, en **Avanzado**, el mouse (para juegos, o libre como en escritorio remoto), el códec y la calidad de imagen se ajustan por máquina.
- La máquina puede transmitir a la frecuencia de tu monitor con los FPS **Monitor**. Se toma en cada apertura y GpuVM agrega esa frecuencia a la pantalla virtual de la VM si no la tiene. A la frecuencia del monitor, la sincronización vertical no agrega latencia y los tirones bajan a la mitad. Las máquinas nuevas la usan, con la sincronización vertical activada.
- Cuando Windows en una máquina pide permiso de administrador, GpuVM muestra una tarjeta pequeña encima de todo, Moonlight incluido, con el programa y su editor; **Permitir** y **Rechazar** lo responden. Solo este equipo puede responder: un programa dentro de la máquina no puede aprobarse a sí mismo.
- Puedes elegir cuándo corre el servicio de GpuVM, en **Preferencias**. **Con GpuVM** (la predeterminada) enciende el servicio al abrir la app y lo apaga al cerrarla, cuando termina lo que estaba haciendo; **Con Windows** lo enciende con Windows; **Manual** lo enciende y apaga solo desde **Preferencias**, que también muestra su estado.
- Si el servicio de GpuVM está detenido o falta, la app lo dice con un botón para iniciarlo o repararlo.

### Cambiado
- Abrir una máquina encendida tarda 7-10 s hasta ver la imagen en vez de unos 25 s: GpuVM hace cada preparación una vez por arranque de Windows y por una sola conexión, y el botón **Abrir** espera a que aparezca la imagen. Volver a hacer clic trae al frente la ventana de Moonlight abierta en vez de abrir otra.
- La captura predeterminada ahora es **Rápida** (Windows.Graphics.Capture): la imagen aparece unos 2,6 s después de conectar, cuando la duplicación de escritorio podía quedar en negro hasta que algo cambiara en pantalla, y además se ven los juegos en pantalla completa exclusiva. **Clásica** (duplicación de escritorio) sigue disponible por máquina.
- GpuVM se abre sin permisos de administrador, así los programas que manejan otras ventanas (herramientas de teclado, control o accesibilidad) también pueden manejarlo. El nuevo servicio de Windows **GpuVM** hace el trabajo de Hyper-V con los permisos de administrador de tu cuenta.
- Borrar una máquina, un disco, un disco compartido o una plantilla pide confirmarlo en un aviso de administrador de Windows; si dices que no, no se borra nada.
- GpuVM trae su propio PowerShell 7 (7.6.9), así la app ya no necesita tenerlo instalado.
- Los grupos de opciones pasan a una opción por fila cuando la ventana es angosta, en vez de partirse dentro de su píldora.

### Seguridad
- Solo la app de GpuVM, abierta por una cuenta de administrador con sesión iniciada en el equipo, puede usar el servicio; otros programas y conexiones de red se rechazan.
- Los archivos y carpetas que nombra una petición (un ISO, una carpeta a importar) se abren primero con tus propios permisos, sin elevar, y se rechazan las rutas que pasan por un enlace a otro lugar.

### Corregido
- Abrir una máquina apagada ya no espera hasta 20 minutos su dirección de red: GpuVM avisa al instante que está apagada.
- El mensaje de memoria dice exactamente cuánta memoria libre necesita la máquina, con el margen de seguridad incluido.
- Una petición mal formada ya no detiene el proceso de PowerShell del módulo.
- Después de crear una máquina, la app la abre en vez de volver a **Inicio**.
- Sitio de documentación: el botón de menú solo aparece en el celular, con un solo ícono (tres líneas cerrado, X abierto) y con espacio junto al selector de idioma; el índice de la derecha es más angosto.
- Sitio de documentación: las tablas de dos columnas sin títulos ya no muestran una primera fila vacía.

## [0.4.1] - 2026-10-28

### Añadido
- Un sitio web en [alenj0x1.github.io/gpuvm](https://alenj0x1.github.io/gpuvm/): la app misma, en vivo y para usar con datos de ejemplo (Inicio, una máquina, plantillas, discos compartidos, Windows limpio), los patrones y perfiles, lo nuevo de la última versión (leído de este changelog) y la instalación. La documentación pasa a [/gpuvm/docs](https://alenj0x1.github.io/gpuvm/docs/).
- Tres clics rápidos en el patrón de cualquier máquina cambian todos los patrones a morado, negro y azul; otros tres los devuelven.

### Cambiado
- El encabezado de la máquina pasa a dos líneas en una ventana angosta en vez de apretar sus botones.

### Corregido
- Elegir una opción de un selector dentro de un formulario (como **Desde plantilla** en **Crear máquina**) ya no envía el formulario ni crea la máquina.

## [0.4.0] - 2026-10-28

### Añadido
- **Inicio.** La app abre en **Inicio**, con tu última máquina, la memoria libre y lo que necesita atención. Muestra la última máquina que abriste, lista para volver a abrirla; cuánta memoria tiene libre el equipo, qué la usa más y si cabe cada máquina; y lo que necesita atención en todas (un driver de la GPU desactualizado, Moonlight sin emparejar, apps pendientes, la contraseña de Windows sin guardar, poco espacio en el disco), cada cosa con el botón que la arregla.
- **Memoria antes del clic.** Una máquina que no cabe en memoria lo dice antes de abrirla, con cuánto le falta, y ofrece abrirla con la memoria que sí cabe en un clic, en la máquina y en Inicio.
- **Plantillas.** Guarda el Windows de una VM, con sus apps, nivel de limpieza y contraseña, como disco base de solo lectura (**⋯ → Crear plantilla**). Una VM creada desde ella recibe un disco diferencial que solo guarda lo que cambia: queda lista en segundos y ocupa pocos GB. Cada copia tiene su propia identidad de Sunshine (Moonlight se empareja con ella como un equipo nuevo) y su propio nombre de equipo. La pestaña **Plantillas** de la biblioteca las muestra con las máquinas creadas sobre cada una; no se puede borrar una mientras una máquina dependa de ella (lab 016).
- **Discos compartidos.** Un disco de datos (por ejemplo, una biblioteca de juegos) que pasa de una VM a otra: créalo en la pestaña **Compartidos** de la biblioteca y conéctalo o desconéctalo desde la tarjeta **Discos compartidos** de la VM, también con ella encendida. Dentro recibe una letra de unidad, y un disco de juegos suma `SteamLibrary` a Steam (GpuVM cierra Steam para eso y lo vuelve a abrir). **Importar carpeta** copia una carpeta de este equipo al disco, como una biblioteca de Steam, para no volver a descargar los juegos en la VM (lab 017).
- **Windows limpio.** Elige qué tan limpio queda Windows al crear la VM, en un perfil o después en la tarjeta **Windows** de cada VM: *Privacidad* (datos de diagnóstico al mínimo que permite la edición, sin identificador de publicidad, historial de actividad, sugerencias, Spotlight, Bing en Inicio, Copilot ni Recall), *Sin apps de más* (además quita apps preinstaladas como Noticias, El tiempo, Solitario, Clipchamp, Teams personal y el Outlook nuevo, OneDrive y los widgets) o *Mínimo* (además apaga la telemetría, el informe de errores y servicios que no hacen falta). Cada nivel incluye los anteriores y uno más bajo deshace los ajustes de los más altos; las apps quitadas vuelven desde Microsoft Store. Nunca se tocan Microsoft Defender, Windows Update, SmartScreen, UAC, el firewall, la Store ni Xbox (una prueba lo garantiza). En Pro, Windows no permite bajar los datos de diagnóstico de «Requerido».
- Nueve apps más en el catálogo: Battle.net, EA app, GOG Galaxy, Ubisoft Connect, VLC, OBS Studio, Spotify, 7-Zip y WinRAR, cada una verificada con la firma de su editor y, si la versión está fijada, con su hash. 7-Zip no lo firma su autor, así que se fija solo por hash; Spotify no se deja instalar como administrador, así que se instala como el usuario de la VM.
- El selector de apps tiene buscador y pestañas por categoría, ocupa como mucho cuatro filas y muestra el ícono de cada app a color.

### Seguridad
- Importar a un disco compartido solo copia de este equipo al disco y nunca deja de revisar: un enlace en cualquier parte del destino, o una carpeta que no se puede revisar, detiene la copia, y no se pueden importar las carpetas de GpuVM, Windows ni carpetas que las contengan. Steam nunca se apunta a un `SteamLibrary` que sea un enlace.
- Las plantillas y los discos compartidos solo los pueden leer Administradores y SYSTEM (Hyper-V da a cada VM acceso a sus propios discos), no el proceso de cada VM.
- Los instaladores de apps quedan abiertos, solo de lectura para los demás, desde que se revisan su firma y su hash hasta que terminan, así nada dentro de la VM puede cambiarlos entremedio.

### Cambiado
- Los íconos de las máquinas muestran un animal o un objeto (un zorro, un búho, un planeta, un cohete...) dentro del cuadrado del color de la máquina, en vez de un patrón abstracto; **Otro patrón** pasa al siguiente. El logo de la barra lateral es el ícono de la app.
- La resolución, los FPS y el modo de ventana de Moonlight van lado a lado en una sola fila en **Opciones**.
- Las ventanas de diálogo dejan fijos su encabezado y sus botones y desplazan solo el contenido, con un único scroll (la lista de apps ya no se desplaza por dentro). **Crear máquina** usa dos columnas, y su botón, como **Guardar perfil**, queda deshabilitado hasta que el formulario esté completo, con los errores junto a cada campo mientras escribes.
- Los botones, casillas, sliders y el foco usan un solo azul fijo en vez del color de cada máquina, para que una acción nunca se vea roja como una advertencia; el rojo queda para borrar y para errores. El color de la máquina sigue en su patrón.

## [0.3.0] - 2026-10-28

### Cambiado
- **Audio real sin Steam.** La salida de VB-CABLE le llegaba muda a Sunshine dentro de la VM; el sonido que parecía funcionar venía de Steam Streaming Speakers (laboratorio 011). Ahora la VM tiene el altavoz USB propio de GpuVM, **Altavoces (GpuVM Audio)**: un servidor dentro de la VM presenta un dispositivo de audio USB, usbip-win2 (drivers firmados por Microsoft) lo conecta y Windows lo maneja con su propio driver. Llega a Moonlight con más volumen que los altavoces de Steam, no necesita reinicio, vuelve solo después de cada reinicio y nunca sale de la VM (`127.0.0.1`, `LOCAL SERVICE`). Las VMs existentes pasan a él la próxima vez que se abren (laboratorio 012).
- El primer arranque ya no reinicia la VM por el audio.
- `components-update` se salta los componentes retenidos; usbip-win2 se mantiene en 0.9.8.0 hasta que un laboratorio pruebe una versión nueva.

### Seguridad
- **La VM queda aislada de tu red por defecto.** Conserva internet, pero no llega a este equipo ni a tu red local, salvo al DHCP y DNS del Default Switch y a las respuestas de las conexiones que abre Moonlight. Las reglas viven en el puerto del switch virtual de la VM y las aplica el equipo, así que una VM dañada o infectada no puede quitarlas; se renuevan antes de cada encendido porque el Default Switch cambia la dirección del equipo. Se desactiva por VM en **Opciones → Red** (por ejemplo, para llegar a un NAS). No se aplica en un switch externo, con un aviso (laboratorio 010).

## [0.2.0] - 2026-10-27

### Agregado
- **Biblioteca** (ícono de capas en la barra de título) con tres pestañas:
  - **Perfiles**: crea, edita, duplica y borra tus propios perfiles a partir de los incluidos. Cada uno guarda procesador, memoria, parte de la GPU, tamaño y tipo de disco, ISO de Windows, apps por instalar y cómo abre Moonlight (resolución, FPS, pantalla completa o ventana). «Crear máquina» llena todo con el perfil elegido.
  - **Discos**: muestra qué VM usa cada disco, vuelve a crear una VM con un disco que se conservó al eliminarla, o borra los discos libres.
  - **ISOs**: recuerda las ISOs que usaste (con las máquinas que las usaron) y las ofrece primero; puedes agregarlas o quitarlas de la lista.
- **Apps para instalar en la VM**: Steam, Epic Games, Discord, Chrome, Proton VPN y Firefox. Se eligen al crear la máquina (se instalan la primera vez que se abre) o después desde la tarjeta Apps de la VM. Cada instalador se descarga dentro de la VM y solo se ejecuta si Windows confirma que lo firma su empresa; las versiones fijas también se comprueban por SHA-256.
- **Pegar en la VM**: un botón pasa el texto copiado en este equipo al portapapeles de la VM, listo para Ctrl+V. Solo va del PC a la VM; la VM nunca lee el portapapeles de este equipo.
- **Opción de captura** por VM (Opciones → Captura): «Estándar» (por defecto) o «Pantalla completa exclusiva», que además muestra programas en pantalla completa exclusiva a cualquier resolución. En ese modo los avisos de administrador de Windows no se ven en el stream.
- **Ampliar el disco** desde Opciones; el disco C: de la VM crece solo la próxima vez que se abre.
- **Abrir en ventana**: Moonlight puede abrir la VM en pantalla completa o en una ventana del tamaño de la resolución elegida.
- **Preferencia «Al salir de GpuVM»**: dejar las máquinas encendidas o apagarlas de forma ordenada.
- Clic en el patrón de una máquina o perfil para cambiarlo; el nuevo se ve en todas partes al instante.
- Labs 008 (tiempo de arranque del stream) y 009 (captura de programas en pantalla completa exclusiva), y un medidor de latencia de punta a punta en `tools/latency`.

### Cambiado
- **Abrir una VM es mucho más rápido**: si GpuVM ya apagó la pantalla de Hyper-V, Sunshine ya no reconfigura la pantalla en cada sesión, lo que lo obligaba a volver a probar todos sus codificadores. El primer cuadro llega en unos 2 s en vez de 22–27 s (lab 008).
- La pantalla virtual queda como la única y principal de la VM, así que las ventanas nuevas siempre aparecen donde se ve el stream; si ya está así, no se toca nada.
- En pantalla completa, Alt+F4, Alt+Tab y la tecla Windows van a la VM en vez de cerrar o sacarte de Moonlight (Ctrl+Alt+Shift+Q sale del stream).
- Windows Update ya no instala drivers de GPU en la VM (reemplazarían el copiado del host).
- El procesador de la VM ya no oculta instrucciones como AVX2 (compatibilidad de migración apagada).
- Se rehicieron los labs 006 y 007: el host usa el planificador root de Hyper-V, donde la reserva y el peso de CPU no tienen efecto, y la candidata de NVENC era igual a los valores por defecto de Sunshine.
- Los mensajes de espera dicen lo que pasa (un reinicio de Sunshine ya no aparece como primer arranque).

### Corregido
- Aplicar Opciones fallaba en toda VM con TPM virtual (Hyper-V no deja cambiar la plantilla de Secure Boot una vez iniciado el TPM).
- Windows y los programas podían abrirse en una salida oculta de 1024×768 de la GPU compartida en vez de la pantalla transmitida.
- Siluetas de carga casi invisibles o apiladas sin espacio; diálogos que se desbordaban en ventanas angostas; íconos de apps desalineados.

### Seguridad
- Moonlight corre sin permisos de administrador, así que una VM comprometida que hable con él no puede alcanzar un proceso elevado en el host.
- La dirección de la VM solo se acepta si está dentro de la red de Hyper-V del host, y la API de Sunshine no sigue redirecciones.
- Cuando el host debe abrir el disco de una VM (actualizar el driver), lo monta sin letra de unidad y rechaza los enlaces puestos dentro, para que una VM no pueda redirigir escrituras a archivos del host.
- `C:\GpuVM` y `%ProgramData%\GpuVM` se revisan y restringen a Administradores y SYSTEM cada vez (los procesos de las VMs solo leen); el proceso elevado ignora módulos y ajustes del entorno del usuario, y la versión publicada no tiene respaldos de desarrollo.
- Las VMs no pueden hacerse pasar por servidor DHCP ni router en la red (protecciones DHCP y router activadas).

## [0.1.1] - 2026-10-27

### Corregido
- **Audio con Windows en otros idiomas.** La VM nunca configuraba el audio de Sunshine si Windows no estaba en inglés, porque la salida del cable tiene un nombre traducido («Altavoces (VB-Audio Virtual Cable)» en español). Ahora se busca por tipo de dispositivo, así que la imagen llega con sonido con Windows en cualquier idioma.
- **«Encender y abrir» repara el audio** de las VMs creadas antes de esta corrección: si la contraseña de Windows de la VM está guardada, hace que Sunshine capture la salida del cable cuando todavía no lo hace.
- Sunshine solo se reinicia cuando su configuración cambia de verdad.

### Agregado
- Licencia MIT.

## [0.1.0] - 2026-10-27

Primera versión.

### Agregado
- **App de escritorio** (Tauri 2 + React): todas las VMs de Hyper-V en una lista, «Encender y abrir» en un clic, estadísticas en vivo de CPU, memoria y GPU, opciones (procesadores, memoria, parte de la GPU, resolución y FPS de Moonlight), asistente para crear máquinas y acciones de energía. Temas claro y oscuro con barra de título y borde de ventana propios que siguen el tema.
- **Preferencias**: tema (sistema, claro u oscuro, también desde la barra de título) y qué hace cerrar la ventana (salir por completo o quedarse en la bandeja del sistema). Abrir GpuVM otra vez muestra la ventana que ya está abierta.
- **VMs Windows con la GPU del equipo** mediante GPU partitioning de Hyper-V (GPU-P): la imagen de Windows se aplica directo a un VHDX, el driver del host se copia al invitado y la instalación es desatendida (cuenta local, inicio de sesión automático, sin OOBE).
- **Streaming**: Sunshine dentro de la VM captura una pantalla virtual dibujada por la GPU y codifica con NVENC; Moonlight en el host la abre. El emparejamiento es automático (el PIN se entrega a Sunshine por su API).
- **Audio silencioso** con VB-CABLE (firmado WHQL), con el crédito a VB-Audio que pide su licencia.
- **Autorreparación al «Encender y abrir»**: sincroniza el driver de la GPU si el del host cambió, espera a Windows y a Sunshine, devuelve la sesión de Windows a la pantalla de la GPU, elige la pantalla virtual en Sunshine y ajusta su resolución a la de Moonlight.
- **Perfiles** en JSON con herencia (`balanced`, `max-performance`) y ajustes por VM.
- **Laboratorios** para medir cada mejora (base contra candidata) antes de adoptarla, con siete laboratorios abiertos.
- **CLI** `gpuvm.ps1` y módulo de PowerShell `GpuVM` con las mismas funciones.
- Instalador NSIS (para todo el equipo, en Program Files) con el módulo, los perfiles y los scripts del invitado incluidos.

### Seguridad
- La app, que corre como administrador, solo ejecuta scripts de Program Files, y PowerShell 7 solo desde Program Files (MSI o carpeta del paquete de Microsoft Store).
- Los datos que cambian (laboratorios, descargas) viven en `%ProgramData%\GpuVM`, solo para administradores.
- Los instaladores de terceros están fijados por SHA-256 y se vuelven a verificar justo antes de copiarlos a la VM.
- Las credenciales de streaming y del invitado se cifran con DPAPI.

[0.9.0]: https://github.com/alenj0x1/gpuvm/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/alenj0x1/gpuvm/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/alenj0x1/gpuvm/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/alenj0x1/gpuvm/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/alenj0x1/gpuvm/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/alenj0x1/gpuvm/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/alenj0x1/gpuvm/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/alenj0x1/gpuvm/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/alenj0x1/gpuvm/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/alenj0x1/gpuvm/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alenj0x1/gpuvm/tree/v0.1.0
