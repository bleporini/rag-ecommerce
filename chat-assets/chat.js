console.log("Chat assets loaded successfully.");

document.head.insertAdjacentHTML(
    "beforeend",
    '<link rel="stylesheet" href="/chat/quikchat.css">'
    );

document.head.insertAdjacentHTML(
    'beforeend',
    '<link rel="stylesheet" href="/chat/chat.css">'
)
const chatDiv = document.createElement('div');
chatDiv.id='chat';
chatDiv.hide = () => chatDiv.style.display = 'none'
chatDiv.show=() => chatDiv.style.display = 'block'
chatDiv.hide();
document.body.appendChild(chatDiv);

const jsTag = document.createElement("script");
jsTag.src = "/chat/quikchat.js";
document.body.appendChild(jsTag)



const btn = document.createElement('button');
btn.classList.add('openchat');
btn.innerHTML = 'Chat';

const sendMsg = msg =>
    fetch('/langchain/chat/invoke',
        {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({input: msg})
        })

const sendMsgStream = (msg, update, finish) => {
    const decoder = new TextDecoder();

    fetch('/langchain/chat/stream',
        {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({input: msg})
    }).then(response => {
        if (!response.ok) {
            throw new Error('Network response was not ok');
        }
        const reader = response.body.getReader();
        const read = () => {
            const eventualRead = reader.read();
            eventualRead.then((r) => {
                    const { done, value } = r;
                    const chunk = decoder.decode(value);

                chunk.split('\n').forEach(line => {
                    if (line.startsWith('data: ') && !line.startsWith('data: {"run_id":')) {
                        const data = line.slice(6).trim().replaceAll('"', '');
                        update(data.replaceAll('\\n', '<br>'));
                    }
                });

                    if (!done) {
                        read();
                    }
                }
            )
        }
        read();
    });

}

jsTag.onload= () => {
    btn.onclick = () =>{
        chatDiv.show();
        const chat = new quikchat('#chat', (instance, message) => {
            // Echo user message
            instance.messageAddNew(message, 'You', 'right');

            let msgId;
            sendMsgStream(
                message+ ". show the links as html links",
                data => {
                    if(!msgId) {
                        msgId = instance.messageAddNew(data, 'Bot', 'left');
                    }else{
                        instance.messageReplaceContent(msgId, instance.messageGetContent(msgId) + data);
                    }
                }
            );

/*
           sendMsg(message+ ". show the links as html links").then(
                response => response.json()
            ).then(data => {
                // Add bot response
                instance.messageAddNew(data.output, 'Bot', 'left');
            }).catch(error => {
                console.error('Error:', error);
                instance.messageAddNew('Sorry, something went wrong.', 'Bot', 'left');
            });
*/

        });

        // Add welcome message
        chat.messageAddNew('Hello! How can I help you today?', 'Bot', 'left');
    }
};

document.body.appendChild(btn);