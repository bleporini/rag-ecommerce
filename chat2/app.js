document.addEventListener('DOMContentLoaded', () => {
    const discussionIdElement = document.getElementById('discussionId');
    const messagesDiv = document.getElementById('messages');
    const textInput = document.getElementById('textInput');
    const sendButton = document.getElementById('sendButton');

    // Generate a unique discussion ID for this session
    const discussionId = `discussion-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;
    discussionIdElement.textContent = discussionId;

    // --- SSE Connection ---
    console.log(`Connecting to SSE endpoint: /chat2-api/chat/${discussionId}`);
    const eventSource = new EventSource(`/chat2-api/chat/${discussionId}`);

    eventSource.onopen = () => {
        console.log('SSE connection established.');
        addMessage('System', 'Connection to server established.', 'system');
    };

    eventSource.onmessage = (event) => {
        console.log('SSE message received:', event.data);
        addMessage('LLM', event.data, 'answer');
    };

    eventSource.onerror = (error) => {
        console.error('SSE error:', error);
        addMessage('System', 'Connection error or stream closed.', 'system');
        eventSource.close();
    };

    // --- Sending Questions ---
    sendButton.addEventListener('click', sendQuestion);
    textInput.addEventListener('keyup', (event) => {
        if (event.key === 'Enter') {
            sendQuestion();
        }
    });

    async function sendQuestion() {
        const text = textInput.value;
        if (!text.trim()) return;

        addMessage('You', text, 'question');
        textInput.value = '';

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
                addMessage('System', `Error sending question: ${errorData.detail || response.statusText}`, 'system');
            } else {
                console.log('Question sent successfully.');
            }
        } catch (error) {
            console.error('Error sending fetch request:', error);
            addMessage('System', 'Failed to send question to the server.', 'system');
        }
    }

    // --- UI Helper ---
    function addMessage(sender, text, type) {
        const messageElement = document.createElement('div');
        messageElement.classList.add('message', type);
        messageElement.innerHTML = `<strong>${sender}:</strong> ${text}`;
        messagesDiv.appendChild(messageElement);
        messagesDiv.scrollTop = messagesDiv.scrollHeight; // Auto-scroll to bottom
    }
});