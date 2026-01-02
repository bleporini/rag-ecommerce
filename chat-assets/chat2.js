console.log("Chat2 assets (quikchat integration) loaded successfully.");

// Inject CSS for quikchat and custom chat styling
document.head.insertAdjacentHTML(
    "beforeend",
    '<link rel="stylesheet" href="/chat/quikchat.css">'
);
document.head.insertAdjacentHTML(
    'beforeend',
    '<link rel="stylesheet" href="/chat/chat.css">'
);

// Create the chat container div
const chatDiv = document.createElement('div');
chatDiv.id = 'chat';
chatDiv.style.display = 'none'; // Initially hidden
document.body.appendChild(chatDiv);

// Create the button to open the chat
const btn = document.createElement('button');
btn.classList.add('openchat');
btn.innerHTML = 'Chat';
document.body.appendChild(btn);

// Load quikchat.js library
const jsTag = document.createElement("script");
jsTag.src = "/chat/quikchat.js";
document.body.appendChild(jsTag);


// Main logic runs after quikchat.js is loaded
jsTag.onload = () => {
    let chatInstance; // Will hold the quikchat instance

    // Generate a unique discussion ID for this session
    const discussionId = `discussion-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;

    // --- SSE Connection ---
    console.log(`Connecting to SSE endpoint: /chat2-api/chat/${discussionId}`);
    const eventSource = new EventSource(`/chat2-api/chat/${discussionId}`);

    eventSource.onopen = () => {
        console.log('SSE connection established.');
        if (chatInstance) {
            chatInstance.messageAddNew('Connection to server established.', 'System', 'left');
        }
    };

    eventSource.onmessage = (event) => {
        console.log('SSE message received:', event.data);
        if (chatInstance) {
            // We expect the raw HTML string from the server
            chatInstance.messageAddNew(event.data, 'LLM', 'left');
        }
    };

    eventSource.onerror = (error) => {
        console.error('SSE error:', error);
        if (chatInstance) {
            chatInstance.messageAddNew('Connection error or stream closed.', 'System', 'left');
        }
        eventSource.close();
    };

    // --- Sending Questions ---
    async function sendQuestion(text) {
        if (!text.trim()) return;

        // UI is updated by quikchat, just send the request
        try {
            const response = await fetch(`/chat2-api/questions/${discussionId}`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({ text: text }),
            });

            if (!response.ok) {
                const errorData = await response.json();
                console.error('Failed to send question:', errorData);
                if (chatInstance) {
                    chatInstance.messageAddNew(`Error: ${errorData.detail || response.statusText}`, 'System', 'left');
                }
            } else {
                console.log('Question sent successfully.');
            }
        } catch (error) {
            console.error('Error sending fetch request:', error);
            if (chatInstance) {
                chatInstance.messageAddNew('Error: Could not send question to server.', 'System', 'left');
            }
        }
    }

    // --- Button and quikchat initialization ---
    btn.onclick = () => {
        chatDiv.style.display = 'block';

        if (chatInstance) { // If chat already initialized, just show it
            return;
        }
        
        // Initialize quikchat
        chatInstance = new quikchat('#chat', (instance, message) => {
            // Echo user message
            instance.messageAddNew(message, 'You', 'right');
            // Send question to the backend
            sendQuestion(message);
        });

        // Add a welcome message
        chatInstance.messageAddNew('Hello! How can I help you today?', 'Bot', 'left');
    };
};
